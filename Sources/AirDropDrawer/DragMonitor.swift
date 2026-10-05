import AppKit
import DrawerCore

@MainActor final class DragMonitor: NSObject {
    let store = StagingStore()
    private var intent = PointerIntent()
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var armed = false
    private var outgoing = false
    private var cleanupGeneration = 0
    private var outsideSince: TimeInterval?
    private var keepOpenUntil: TimeInterval = 0
    private var hoverBlockedUntil: TimeInterval = 0
    private(set) var panels: [DrawerPanel] = []
    var onDrop: (([URL], DrawerPanel) -> Void)?
    var paused = false {
        didSet {
            cancel()
            panels.forEach { $0.receiver.acceptsDrops = !paused }
        }
    }

    override init() {
        super.init()
        rebuildPanels()
        store.onChange = { [weak self] in self?.panels.forEach { $0.receiver.reloadEntries() } }
    }
    func start() {
        let timer = Timer(timeInterval: 1.0 / 45, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        timer.tolerance = 0.006
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panels.forEach { if $0.expanded { $0.receiver.setVisible(true) } }
                }
            }
    }
    func stop() {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        cancel()
        store.reset()
    }

    @objc private func sample() {
        guard !outgoing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        let down = buttons & 1 != 0
        let dragging = intent.drag(buttonDown: down, point: point)
        if !paused && dragging {
            cleanupGeneration += 1
            if !armed {
                armed = true
                panels.forEach { $0.arm() }
                AppLog.event("native receivers armed")
            }
        } else if armed {
            armed = false
            cleanupGeneration += 1
            let token = cleanupGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, token == cleanupGeneration else { return }
                panels.filter { !$0.expanded }.forEach { $0.disarm() }
            }
        }
        let hoverPanel = panels.first { PointerIntent.containsTopEdge(point, in: $0.hoverFrame) }
        if intent.hover(inside: !paused && hoverPanel != nil && now >= hoverBlockedUntil, buttonsDown: buttons != 0, now: now),
           let panel = hoverPanel, !panel.expanded {
            show(panel)
        }
        guard let open = panels.first(where: { $0.expanded }), !down else { outsideSince = nil; return }
        if PointerIntent.containsTopEdge(point, in: open.frame) || now < keepOpenUntil {
            outsideSince = nil
        } else if let outsideSince, now - outsideSince > 0.4 {
            open.dismiss()
            self.outsideSince = nil
        } else if outsideSince == nil { outsideSince = now }
    }

    private func rebuildPanels() {
        // Don't destroy an AppKit source view while its drag is in flight.
        guard !outgoing else { return }
        cancel()
        panels = NSScreen.screens.map { screen in
            let panel = DrawerPanel(screen: screen, store: store)
            panel.receiver.acceptsDrops = !paused
            panel.onDrop = { [weak self] urls, zone, source in self?.accept(urls, zone: zone, source: source) ?? false }
            panel.onNativeEnter = { [weak self, weak panel] in
                self?.panels.filter { $0 !== panel }.forEach { $0.disarm(); $0.arm() }
            }
            panel.onDragEnd = { [weak self] in self?.finishNativeDrag() }
            panel.receiver.onOutgoingBegin = { [weak self] in
                guard let self else { return }
                outgoing = true
                cleanupGeneration += 1
                panels.forEach { $0.hideForOutgoingDrag() }
            }
            panel.receiver.onOutgoingEnd = { [weak self] in
                guard let self else { return }
                outgoing = false
                cancel()
                hoverBlockedUntil = ProcessInfo.processInfo.systemUptime + 0.5
                DispatchQueue.main.async { [weak self] in self?.rebuildPanels() }
            }
            return panel
        }
    }

    private func accept(_ urls: [URL], zone: DropZone, source: DrawerPanel) -> Bool {
        guard !paused, !outgoing else { return false }
        intent.consume()
        cleanupGeneration += 1
        armed = false
        switch zone {
        case .airDrop:
            panels.forEach { $0.disarm() }
            DispatchQueue.main.async { [weak self] in self?.onDrop?(urls, source) }
        case .staging:
            do {
                let count = try store.add(urls)
                source.receiver.showMessage(count == 0 ? "这些文件已在暂存区" : "已暂存 \(count) 个项目")
                keepOpenUntil = ProcessInfo.processInfo.systemUptime + 0.9
                panels.filter { $0 !== source }.forEach { $0.disarm() }
                AppLog.event("staged count: \(count)")
            } catch {
                source.receiver.showRejection(error.localizedDescription)
                keepOpenUntil = ProcessInfo.processInfo.systemUptime + 3
                return false
            }
        }
        return true
    }
    private func finishNativeDrag() {
        intent.consume()
        cleanupGeneration += 1
        armed = false
        panels.filter { !$0.expanded }.forEach { $0.disarm() }
    }
    func cancel() {
        intent.consume()
        cleanupGeneration += 1
        armed = false
        outsideSince = nil
        panels.forEach { $0.disarm() }
    }
    private func show(_ panel: DrawerPanel) {
        panels.filter { $0 !== panel }.forEach { $0.disarm() }
        panel.expand()
        outsideSince = nil
        keepOpenUntil = ProcessInfo.processInfo.systemUptime + 0.7
    }
    func openStaging() {
        guard !outgoing else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let panel = panels.first(where: { $0.display == screen }) { show(panel); keepOpenUntil = ProcessInfo.processInfo.systemUptime + 2 }
    }
    func preview(duration: TimeInterval = 3) { openStaging() }
}
