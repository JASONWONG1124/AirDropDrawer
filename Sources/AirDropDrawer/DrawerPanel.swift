import AppKit
import QuartzCore
import QuickLookThumbnailing
import DrawerCore

enum DropZone { case airDrop, staging }

@MainActor final class DrawerPanel: NSPanel {
    let display: NSScreen
    let receiver: FileDropView
    private(set) var expanded = false
    private var generation = 0
    var onDrop: (([URL], DropZone, DrawerPanel) -> Bool)?
    var onDragEnd: (() -> Void)?
    var onNativeEnter: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var triggerFrame: NSRect {
        let width = min(660, display.frame.width)
        return NSRect(x: display.frame.midX - width / 2, y: display.frame.maxY - 48, width: width, height: 48)
    }
    var hoverFrame: NSRect {
        NSRect(x: triggerFrame.minX, y: display.frame.maxY - 8, width: triggerFrame.width, height: 8)
    }
    var expandedFrame: NSRect {
        let height = min(360 + display.safeAreaInsets.top, display.frame.height)
        return NSRect(x: triggerFrame.minX, y: display.frame.maxY - height, width: triggerFrame.width, height: height)
    }

    init(screen: NSScreen, store: StagingStore = StagingStore()) {
        display = screen
        receiver = FileDropView(store: store)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = receiver
        receiver.autoresizingMask = [.width, .height]
        receiver.safeTop = screen.safeAreaInsets.top
        receiver.onEnter = { [weak self] urls in
            guard let self else { return }
            onNativeEnter?()
            expand(urls: urls)
        }
        receiver.onReject = { [weak self] reason in
            self?.expand(urls: [], preview: true)
            self?.receiver.showRejection(reason)
        }
        receiver.onDrop = { [weak self] urls, zone in
            guard let self else { return false }
            return onDrop?(urls, zone, self) ?? false
        }
        receiver.onEnd = { [weak self] in self?.onDragEnd?() }
        disarm()
    }

    func arm() {
        generation += 1
        alphaValue = 1
        ignoresMouseEvents = false
        guard !expanded else { receiver.setVisible(true); return }
        receiver.setVisible(false)
        setFrame(triggerFrame, display: false)
        orderFrontRegardless()
    }

    func expand(urls: [URL] = [], preview: Bool = false) {
        generation += 1
        alphaValue = 1
        ignoresMouseEvents = false
        let wasExpanded = expanded
        expanded = true
        setFrame(expandedFrame, display: true)
        receiver.setVisible(true)
        if !wasExpanded { receiver.reloadEntries() }
        orderFrontRegardless()
        if !wasExpanded { receiver.animateIn() }
        AppLog.event("drawer expanded")
    }

    // The source view and window must survive the entire AppKit dragging session.
    func hideForOutgoingDrag() {
        generation += 1
        alphaValue = 0
        ignoresMouseEvents = true
    }

    func dismiss(animated: Bool = true) {
        generation += 1
        let token = generation
        ignoresMouseEvents = true
        if animated && expanded {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.disarm()
                }
            }
        } else { disarm() }
    }

    func disarm() {
        generation += 1
        expanded = false
        ignoresMouseEvents = true
        orderOut(nil)
        alphaValue = 1
        receiver.setVisible(false)
        receiver.highlight(nil)
    }
}

@MainActor final class FileDropView: NSView {
    let store: StagingStore
    var onEnter: (([URL]) -> Void)?
    var onReject: ((String) -> Void)?
    var onDrop: (([URL], DropZone) -> Bool)?
    var onEnd: (() -> Void)?
    var onOutgoingBegin: (() -> Void)?
    var onOutgoingEnd: (() -> Void)?
    var safeTop: CGFloat = 0
    var acceptsDrops = true
    private let glass = NSGlassEffectView(frame: .zero)
    private let opaqueSurface = NSView(frame: .zero)
    private let body = NSView(frame: .zero)
    private let airBox = NSView(frame: .zero)
    private let stageBox = NSView(frame: .zero)
    private let symbol = NSImageView(frame: .zero)
    private let airTitle = NSTextField(labelWithString: "AirDrop")
    private let airDetail = NSTextField(labelWithString: "拖到这里\n选择设备发送")
    private let stageTitle = NSTextField(labelWithString: "文件暂存")
    private let hint = NSTextField(labelWithString: "拖入暂存 · 拖出使用 · 退出后清空")
    private let empty = NSTextField(labelWithString: "把文件放在这里\n切换窗口后，再拖出去")
    private let clearButton = NSButton(title: "清空", target: nil, action: nil)
    private let undoButton = NSButton(title: "撤销清空", target: nil, action: nil)
    private let scroll = NSScrollView(frame: .zero)
    private let list = FileIconGrid(frame: .zero)
    private var currentURLs: [URL] = []
    private var acceptedSequence: Int?
    private var dragValid = false
    private var sourceTile: FileTileView?
    private var messageGeneration = 0
    private var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var airDropFrame: NSRect { airBox.frame }
    var stagingFrame: NSRect { stageBox.frame }

    init(store: StagingStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        // Preserve 0.3.1's public system material, without simulated glass overlays.
        glass.style = .regular
        glass.cornerRadius = 30
        opaqueSurface.wantsLayer = true
        opaqueSurface.layer?.cornerRadius = 30
        addSubview(glass)
        addSubview(opaqueSurface)
        for box in [airBox, stageBox] {
            box.wantsLayer = true
            box.layer?.cornerRadius = 18
            body.addSubview(box)
        }
        symbol.image = NSImage(systemSymbolName: "airdrop", accessibilityDescription: "隔空投送")
            ?? NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "隔空投送")
        symbol.symbolConfiguration = .init(pointSize: 35, weight: .regular)
        symbol.contentTintColor = .controlAccentColor
        for label in [airTitle, stageTitle] { label.font = .systemFont(ofSize: 17, weight: .semibold) }
        airTitle.alignment = .center
        airDetail.alignment = .center
        airDetail.font = .systemFont(ofSize: 12)
        airDetail.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        for view in [symbol, airTitle, airDetail, stageTitle, hint, empty, clearButton, undoButton, scroll] { body.addSubview(view) }
        clearButton.bezelStyle = .inline
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.setAccessibilityLabel("清空暂存区，不删除原文件")
        undoButton.bezelStyle = .inline
        undoButton.target = self
        undoButton.action = #selector(undo)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = list
        setAccessibilityLabel("AirDrop 与文件暂存抽屉")
        setVisible(false)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glass.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 30)
        opaqueSurface.frame = glass.frame
        body.frame = bounds
        let contentHeight = max(0, bounds.height - safeTop - 24)
        let leftWidth: CGFloat = min(166, bounds.width * 0.27)
        airBox.frame = NSRect(x: 14, y: 14, width: leftWidth, height: contentHeight)
        stageBox.frame = NSRect(x: airBox.frame.maxX + 12, y: 14, width: max(0, bounds.width - leftWidth - 40), height: contentHeight)
        symbol.frame = NSRect(x: airBox.frame.midX - 24, y: airBox.frame.midY + 22, width: 48, height: 48)
        airTitle.frame = NSRect(x: airBox.frame.minX + 4, y: airBox.frame.midY - 10, width: leftWidth - 8, height: 25)
        airDetail.frame = NSRect(x: airBox.frame.minX + 4, y: airBox.frame.midY - 57, width: leftWidth - 8, height: 40)
        stageTitle.frame = NSRect(x: stageBox.frame.minX + 14, y: stageBox.frame.maxY - 35, width: 175, height: 25)
        clearButton.frame = NSRect(x: stageBox.frame.maxX - 52, y: stageBox.frame.maxY - 33, width: 40, height: 23)
        undoButton.frame = NSRect(x: stageBox.frame.maxX - 132, y: stageBox.frame.maxY - 33, width: 76, height: 23)
        hint.frame = NSRect(x: stageBox.frame.minX + 14, y: stageBox.frame.minY + 10, width: stageBox.frame.width - 28, height: 17)
        scroll.frame = NSRect(x: stageBox.frame.minX + 8, y: stageBox.frame.minY + 35,
                              width: stageBox.frame.width - 16, height: max(0, stageBox.frame.height - 78))
        empty.frame = NSRect(x: scroll.frame.minX + 8, y: scroll.frame.midY - 24, width: scroll.frame.width - 16, height: 48)
        list.arrange(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
    }

    func setVisible(_ visible: Bool) {
        glass.isHidden = !visible || reduceTransparency
        opaqueSurface.isHidden = !visible || !reduceTransparency
        if reduceTransparency {
            glass.contentView = nil
            if body.superview !== opaqueSurface { opaqueSurface.addSubview(body) }
            opaqueSurface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            if body.superview === opaqueSurface { body.removeFromSuperview() }
            glass.contentView = body
        }
        needsLayout = true
    }

    func animateIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
        layer?.add(fade, forKey: "appear")
    }

    func reloadEntries() {
        guard sourceTile == nil else { return }
        list.subviews.forEach { $0.removeFromSuperview() }
        for entry in store.entries {
            _ = try? entry.resolve()
            let row = FileTileView(entry: entry)
            row.onRemove = { [weak self] in self?.store.remove(entry.id) }
            row.onError = { [weak self] message in self?.showMessage(message, error: true) }
            row.onBegin = { [weak self, weak row] in
                self?.sourceTile = row
                self?.onOutgoingBegin?()
            }
            row.onEnd = { [weak self] in
                self?.sourceTile = nil
                self?.onOutgoingEnd?()
            }
            list.addSubview(row)
        }
        empty.isHidden = !store.entries.isEmpty
        scroll.isHidden = store.entries.isEmpty
        clearButton.isEnabled = !store.entries.isEmpty
        undoButton.isHidden = !store.canUndo
        stageTitle.stringValue = store.entries.isEmpty ? "文件暂存" : "文件暂存 · \(store.entries.count)"
        needsLayout = true
    }

    @objc private func clear() { store.clear(); showMessage("已清空暂存，原文件未删除") }
    @objc private func undo() { store.undoClear(); showMessage("已恢复暂存条目") }
    func showRejection(_ reason: String) { showMessage(reason, error: true) }
    func showMessage(_ message: String, error: Bool = false) {
        messageGeneration += 1
        let token = messageGeneration
        hint.stringValue = message
        hint.textColor = error ? .systemOrange : .secondaryLabelColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, token == messageGeneration else { return }
            hint.stringValue = "拖入暂存 · 拖出使用 · 退出后清空"
            hint.textColor = .secondaryLabelColor
        }
    }

    func zone(at point: NSPoint) -> DropZone? {
        if airBox.frame.contains(point) { return .airDrop }
        if stageBox.frame.contains(point) { return .staging }
        return nil
    }
    func highlight(_ zone: DropZone?) {
        airBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(zone == .airDrop ? 0.18 : 0.05).cgColor
        stageBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(zone == .staging ? 0.15 : 0.035).cgColor
        airDetail.stringValue = zone == .airDrop ? "松开以隔空投送" : "拖到这里\n选择设备发送"
        if zone == .staging { hint.stringValue = "松开以暂存，原文件留在原处" }
        else if hint.stringValue.hasPrefix("松开以暂存") { hint.stringValue = "拖入暂存 · 拖出使用 · 退出后清空" }
    }
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    func validatedURLs(from pasteboard: NSPasteboard, allowedOperations: NSDragOperation) throws -> [URL] {
        guard allowedOperations.contains(.copy) else {
            throw NSError(domain: "AirDropDrawer", code: 1, userInfo: [NSLocalizedDescriptionKey: "来源不允许提供文件副本"])
        }
        return try DropPayload.validate(Self.fileURLs(from: pasteboard))
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, !(sender.draggingSource is FileTileView) else { return [] }
        do {
            currentURLs = try validatedURLs(from: sender.draggingPasteboard, allowedOperations: sender.draggingSourceOperationMask)
            dragValid = true
            onEnter?(currentURLs)
            layoutSubtreeIfNeeded()
            AppLog.event("native file entered: \(currentURLs.count)")
            return draggingUpdated(sender)
        } catch {
            dragValid = false
            onReject?(error.localizedDescription)
            return []
        }
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, dragValid, sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        let target = zone(at: convert(sender.draggingLocation, from: nil))
        highlight(target)
        return target == nil ? [] : .copy
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlight(nil) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsDrops, zone(at: convert(sender.draggingLocation, from: nil)) != nil else { return false }
        do {
            _ = try validatedURLs(from: sender.draggingPasteboard, allowedOperations: sender.draggingSourceOperationMask)
            return true
        } catch { showRejection(error.localizedDescription); return false }
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsDrops, acceptedSequence != sender.draggingSequenceNumber,
              let target = zone(at: convert(sender.draggingLocation, from: nil)) else { return false }
        do {
            let urls = try validatedURLs(from: sender.draggingPasteboard, allowedOperations: sender.draggingSourceOperationMask)
            acceptedSequence = sender.draggingSequenceNumber
            return onDrop?(urls, target) ?? false
        } catch { showRejection(error.localizedDescription); return false }
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragValid = false
        currentURLs = []
        highlight(nil)
        onEnd?()
    }
}

@MainActor final class FileIconGrid: NSView {
    override var isFlipped: Bool { true }
    func arrange(width: CGFloat, minimumHeight: CGFloat) {
        let gap: CGFloat = 6
        let columns = max(1, Int((width + gap) / 104))
        let tileWidth = max(0, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let rows = (subviews.count + columns - 1) / columns
        frame = NSRect(x: 0, y: 0, width: width, height: max(minimumHeight, CGFloat(rows) * 130))
        for (index, tile) in subviews.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % columns) * (tileWidth + gap),
                                y: CGFloat(index / columns) * 130, width: tileWidth, height: 124)
        }
    }
}

@MainActor final class FileTileView: NSView, NSDraggingSource {
    let entry: StagingStore.Entry
    private let icon = NSImageView(frame: .zero)
    private let name = NSTextField(labelWithString: "")
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var thumbnailToken = UUID()
    private(set) var hasThumbnail = false
    private(set) var thumbnailFinished = false
    private let remove = NSButton(title: "", target: nil, action: nil)
    private var mouseDownPoint: NSPoint?
    private var outgoingAccess: SharedFileAccess?
    var onRemove: (() -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var isDragging: Bool { outgoingAccess != nil }

    init(entry: StagingStore.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        name.stringValue = entry.url.lastPathComponent
        name.font = .systemFont(ofSize: 11)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byWordWrapping
        name.cell?.wraps = true
        name.cell?.truncatesLastVisibleLine = true
        name.textColor = entry.failure == nil ? .labelColor : .systemOrange
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "移除")
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.target = self
        remove.action = #selector(removeEntry)
        remove.toolTip = "移除暂存条目，不删除原文件"
        remove.setAccessibilityLabel("移除 \(entry.url.lastPathComponent)")
        for view in [icon, name, remove] { addSubview(view) }
        toolTip = entry.failure.map { "\(entry.url.path)\n\($0)" } ?? entry.url.path
        setAccessibilityLabel("\(entry.url.lastPathComponent)，按住拖出使用")
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 80) / 2, y: 38, width: 80, height: 80)
        name.frame = NSRect(x: 3, y: 3, width: max(0, bounds.width - 6), height: 30)
        remove.frame = NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 20, height: 20)
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { loadThumbnail() }
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            thumbnailToken = UUID()
            if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
            thumbnailRequest = nil
        }
        super.viewWillMove(toSuperview: newSuperview)
    }
    private func loadThumbnail() {
        guard thumbnailRequest == nil, !hasThumbnail, entry.failure == nil else { return }
        let values = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(entry.url.path)|\(entry.identity.device):\(entry.identity.inode)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        if let cached = Self.thumbnailCache.object(forKey: key as NSString) {
            icon.image = cached
            hasThumbnail = true
            thumbnailFinished = true
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: 80, height: 80),
                                                   scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        thumbnailRequest = request
        let token = thumbnailToken
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let cgImage = representation?.cgImage
            DispatchQueue.main.async {
                guard let self, self.thumbnailToken == token else { return }
                self.thumbnailRequest = nil
                self.thumbnailFinished = true
                guard let cgImage else { return } // Keep the native file icon for unsupported formats.
                let image = NSImage(cgImage: cgImage, size: .zero)
                Self.thumbnailCache.setObject(image, forKey: key as NSString)
                self.icon.image = image
                self.hasThumbnail = true
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return remove.frame.contains(local) ? remove : self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func removeEntry() { onRemove?() }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, !isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 4 else { return }
        do {
            let url = try entry.resolve()
            outgoingAccess = try SharedFileAccess([url])
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let imageSize = icon.image?.size ?? NSSize(width: 80, height: 80)
            let scale = 80 / max(1, max(imageSize.width, imageSize.height))
            let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                         width: size.width, height: size.height), contents: icon.image)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            mouseDownPoint = nil
            AppLog.event("outgoing drag started")
        } catch {
            outgoingAccess = nil
            name.textColor = .systemOrange
            toolTip = "文件不可用，请重新拖入"
            onError?(error.localizedDescription)
            mouseDownPoint = nil
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onBegin?() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        outgoingAccess = nil
        AppLog.event("outgoing drag ended: \(operation.rawValue)")
        onEnd?()
    }
}
