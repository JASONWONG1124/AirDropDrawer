import AppKit
import DrawerCore

@MainActor func runNativeChecks() -> Int32 {
    guard let screen = NSScreen.main else { print("FAIL: no screen"); return 1 }
    var failures = 0
    var checks = 0
    func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
    let store = StagingStore()
    let panel = DrawerPanel(screen: screen, store: store)
    defer { panel.disarm(); store.reset() }
    expect(!panel.isVisible && panel.ignoresMouseEvents, "idle does not intercept menu")
    expect(!panel.canBecomeKey && !panel.canBecomeMain, "drawer doesn't take target keyboard focus")
    expect(panel.triggerFrame.maxY == screen.frame.maxY, "trigger uses physical display")
    expect(panel.hoverFrame.width == panel.triggerFrame.width, "empty-hand opening uses full drawer width")
    expect(PointerIntent.containsTopEdge(NSPoint(x: panel.hoverFrame.midX, y: screen.frame.maxY), in: panel.hoverFrame), "exact top-of-screen pointer accepted")
    panel.arm()
    expect(panel.isVisible && !panel.expanded, "drag can arm receiver before files are read")
    panel.expand()
    panel.receiver.layoutSubtreeIfNeeded()
    expect(panel.expanded && panel.frame.width == panel.triggerFrame.width, "expanded width covers entire trigger")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let glass = descendants(panel.receiver).compactMap { $0 as? NSGlassEffectView }.first
    expect(glass?.style == .regular, "retain 0.3.1 regular native material")
    expect(descendants(panel.receiver).compactMap { $0 as? NSImageView }.first?.image != nil, "AirDrop symbol has supported fallback")
    expect(glass?.appearance == nil, "inherit system appearance")
    expect(!descendants(panel.receiver).contains { $0 is NSVisualEffectView }, "no obsolete simulated glass layers")
    let air = panel.receiver.airDropFrame
    let stage = panel.receiver.stagingFrame
    expect(panel.receiver.zone(at: NSPoint(x: air.midX, y: air.midY)) == .airDrop, "left routes AirDrop")
    expect(panel.receiver.zone(at: NSPoint(x: stage.midX, y: stage.midY)) == .staging, "right routes staging")
    expect(panel.receiver.zone(at: NSPoint(x: (air.maxX + stage.minX) / 2, y: stage.midY)) == nil, "gap never sends")
    panel.dismiss()
    panel.arm()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    expect(panel.isVisible && !panel.ignoresMouseEvents, "stale dismissal cannot hide a new receiver")
    panel.expand()
    panel.hideForOutgoingDrag()
    expect(panel.alphaValue == 0 && panel.ignoresMouseEvents && panel.isVisible, "outgoing drag hides surface but retains source window")
    panel.disarm()

    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Drawer-Staging-\(UUID().uuidString)").resolvingSymlinksInPath()
    do {
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("视频 一.txt")
        let second = fixture.appendingPathComponent("second.txt")
        let folder = fixture.appendingPathComponent("folder")
        try Data("original".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sameName = folder.appendingPathComponent(first.lastPathComponent)
        try Data("different".utf8).write(to: sameName)
        let originalContents = try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted()
        expect(try store.add([first, second, first]) == 2, "multiple files deduplicate")
        expect(try store.add([first]) == 0 && store.entries.count == 2, "repeated drop does not duplicate")
        expect(try store.add([sameName, folder]) == 2, "same filename at different path and folder supported")
        expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted() == originalContents, "staging doesn't copy or move files")
        expect(try Data(contentsOf: first) == Data("original".utf8), "original content unchanged")
        let before = store.entries.count
        do {
            _ = try store.add([second, fixture.appendingPathComponent("missing")])
            expect(false, "invalid batch rejected")
        } catch { expect(store.entries.count == before, "invalid batch commits nothing") }
        let entry = store.entries[0]
        let row = FileTileView(entry: entry)
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        list.addSubview(row)
        row.frame = NSRect(x: 106, y: 130, width: 100, height: 124)
        row.layoutSubtreeIfNeeded()
        expect(row.hitTest(NSPoint(x: 156, y: 195)) === row, "drag area works in a scrolled/later tile")
        expect(row.hitTest(NSPoint(x: 194, y: 242)) is NSButton, "remove button stays clickable within later tile")
        expect(row.hitTest(NSPoint(x: 156, y: 145)) === row, "filename also starts a drag")
        let grid = FileIconGrid(frame: .zero)
        for entry in store.entries { grid.addSubview(FileTileView(entry: entry)) }
        grid.addSubview(FileTileView(entry: entry))
        grid.arrange(width: 418, minimumHeight: 176)
        expect(grid.subviews[0].frame.midY == grid.subviews[3].frame.midY, "four icons fit side by side")
        expect(grid.subviews[4].frame.minY > grid.subviews[0].frame.maxY, "fifth icon wraps without overlap")
        expect(grid.frame.height > 176, "overflow becomes scrollable")
        grid.arrange(width: 180, minimumHeight: 176)
        expect(grid.subviews.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 180 }, "narrow grid stays inside viewport")
        // Exercise the real asynchronous Quick Look provider, not a mock icon.
        let png = fixture.appendingPathComponent("一张用于检查长文件名换行与缩略图比例的图片.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<90 { for x in 0..<160 {
            bitmap.setColor(x < 80 ? NSColor(deviceRed: 0.1, green: 0.5, blue: 0.9, alpha: 1) : NSColor(deviceRed: 1, green: 0.5, blue: 0.1, alpha: 1), atX: x, y: y)
        } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let previewStore = StagingStore()
        try previewStore.add([png])
        if let movie = ProcessInfo.processInfo.environment["DRAWER_CHECK_MOVIE"] {
            try previewStore.add([URL(fileURLWithPath: movie)])
        }
        let previews = previewStore.entries.map { FileTileView(entry: $0) }
        for tile in previews { grid.addSubview(tile) }
        let deadline = Date().addingTimeInterval(15)
        while previews.contains(where: { !$0.thumbnailFinished }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(previews.allSatisfy(\.hasThumbnail), "real image/video gets a content thumbnail")
        let loadedImage = previews[0].subviews.compactMap { $0 as? NSImageView }.first?.image
        expect((loadedImage?.size.width ?? 0) > (loadedImage?.size.height ?? 0), "landscape thumbnail preserves aspect ratio")
        let cachedTile = FileTileView(entry: previewStore.entries[0])
        grid.addSubview(cachedTile)
        expect(cachedTile.hasThumbnail, "reopening reuses completed thumbnail")
        let cancelURL = fixture.appendingPathComponent("cancel.png")
        try FileManager.default.copyItem(at: png, to: cancelURL)
        let cancelStore = StagingStore()
        try cancelStore.add([cancelURL])
        let cancelled = FileTileView(entry: cancelStore.entries[0])
        grid.addSubview(cancelled)
        cancelled.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(!cancelled.hasThumbnail, "cancelled request cannot update a removed tile")
        let unknownURL = fixture.appendingPathComponent("unsupported.drawerfixture")
        try Data([0, 1, 2, 3]).write(to: unknownURL)
        try cancelStore.add([unknownURL])
        let fallback = FileTileView(entry: cancelStore.entries[1])
        grid.addSubview(fallback)
        let fallbackDeadline = Date().addingTimeInterval(5)
        while !fallback.thumbnailFinished && Date() < fallbackDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(!fallback.hasThumbnail && fallback.subviews.compactMap { $0 as? NSImageView }.first?.image != nil,
               "unsupported file keeps usable native icon")
        if let previewPath = ProcessInfo.processInfo.environment["DRAWER_CHECK_PREVIEW"] {
            try previewStore.add([first, folder, sameName])
            let previewPanel = DrawerPanel(screen: screen, store: previewStore)
            previewPanel.expand()
            previewPanel.receiver.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let view = previewPanel.receiver
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewPath))
            }
            previewPanel.disarm()
        }
        // A normal URL writer is what native Finder-compatible destinations consume.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try board.writeObjects([entry.resolve() as NSURL])
        expect(FileDropView.fileURLs(from: board).map { $0.resolvingSymlinksInPath().path } == [first.resolvingSymlinksInPath().path], "outgoing URL pasteboard roundtrip")
        expect(try panel.receiver.validatedURLs(from: board, allowedOperations: .copy).map { $0.resolvingSymlinksInPath().path } == [first.resolvingSymlinksInPath().path], "native file payload validates")
        do {
            _ = try panel.receiver.validatedURLs(from: board, allowedOperations: .move)
            expect(false, "move-only source rejected")
        } catch { expect(true, "move-only source rejected") }
        _ = row // Actual native drag is verified separately with UI.
        store.remove(store.entries[1].id)
        expect(store.entries.count == before - 1 && FileManager.default.fileExists(atPath: second.path), "remove reference only")
        store.clear()
        expect(store.entries.isEmpty && store.canUndo, "clear offers undo")
        _ = try store.add([first])
        store.undoClear()
        expect(store.entries.count == before - 1, "undo merges without duplicate")
        expect(store.entries[0].url == sameName || store.entries[0].url == first, "undo restores original items")
        let renamed = fixture.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: first, to: renamed)
        let recovered = try? entry.resolve()
        expect(recovered?.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path || entry.failure != nil, "rename resolves same file or marks unavailable")
        try Data("replacement".utf8).write(to: first)
        expect((try? entry.resolve()) != first, "replacement at old path must not replace original reference")
        try FileManager.default.removeItem(at: renamed)
        expect((try? entry.resolve()) == nil && entry.failure != nil, "deleted original is invalid")
        store.reset()
        expect(store.entries.isEmpty && !store.canUndo, "exit resets both entries and undo references")
        expect(StagingStore().entries.isEmpty, "new process store starts empty")
        expect(FileManager.default.fileExists(atPath: second.path), "reset doesn't delete originals")
        let denied = fixture.appendingPathComponent("denied.txt")
        try Data("x".utf8).write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }
        do { _ = try store.add([second, denied]); expect(false, "unreadable batch rejected") }
        catch { expect(store.entries.isEmpty, "unreadable batch leaves no partial entries") }
    } catch { expect(false, "fixture: \(error)") }

    let coordinator = AirDropCoordinator()
    coordinator.preparePresentation(from: panel)
    if let service = NSSharingService(named: .sendViaAirDrop) {
        var scope = NSSharingService.SharingContentScope.item
        expect(coordinator.sharingService(service, sourceWindowForShareItems: [], sharingContentScope: &scope) == nil, "chooser independent of drawer")
        expect(screen.visibleFrame.contains(coordinator.sharingService(service, sourceFrameOnScreenForShareItem: "test")), "chooser origin stays onscreen")
        var rect = NSRect.zero
        expect(coordinator.sharingService(service, transitionImageForShareItem: "test", contentRect: &rect) == nil, "no fly-in transition")
    } else { expect(false, "system AirDrop service exists") }
    print("Native checks \(failures == 0 ? "passed" : "failed"): \(checks) checks, \(failures) failures")
    return failures == 0 ? 0 : 1
}
