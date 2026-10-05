import AppKit
import DrawerCore

@MainActor final class AirDropCoordinator: NSObject, NSSharingServiceDelegate {
    private var service: NSSharingService?
    private var presentationFrame = NSRect.zero
    private var sharedURLs: [URL] = []
    private var fileAccess: SharedFileAccess?

    func share(_ urls: [URL], from window: NSWindow) {
        do {
            NSApp.activate()
            let access = try SharedFileAccess(urls)
            let files = access.urls
            guard let next = NSSharingService(named: .sendViaAirDrop) else {
                showError("无法打开隔空投送", detail: "macOS 未提供隔空投送共享服务。请在 Finder 中检查隔空投送是否可用。")
                return
            }
            guard next.canPerform(withItems: files) else {
                AppLog.event("AirDrop rejected readable items: count=\(files.count)")
                showError("系统未接受这些项目", detail: "文件已经可以读取，但 macOS 共享服务仍未接受这次投放。请尝试在 Finder 中共享同一批项目。")
                return
            }
            // A canceled system chooser doesn't always send a delegate callback. A new
            // deliberate drop can replace that old reference, so cancellation never locks the app.
            service?.delegate = nil
            service = next
            fileAccess = access
            preparePresentation(from: window)
            sharedURLs = files
            next.delegate = self
            NSApp.activate()
            next.perform(withItems: files)
            AppLog.event("AirDrop perform requested for \(files.count) files")
        } catch {
            let failure = error as NSError
            AppLog.event("share preparation failed: \(failure.domain) code=\(failure.code)")
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError {
                showError("没有读取这些项目的权限", detail: "请在「系统设置 → 隐私与安全性 → 文件与文件夹」中允许 AirDrop 抽屉访问项目所在位置，然后重新拖入。无需开启完全磁盘访问权限。")
            } else {
                showError("无法投放这些文件", detail: error.localizedDescription)
            }
        }
    }

    func preparePresentation(from window: NSWindow) {
        let screen = (window as? DrawerPanel)?.display ?? window.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            presentationFrame = NSRect(x: frame.midX - 1, y: frame.midY - 1, width: 2, height: 2)
        }
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        // A sheet attached to the top-edge panel extends beyond the physical screen.
        // Let the system present its own chooser instead of attaching to that panel.
        nil
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        presentationFrame
    }

    func sharingService(_ sharingService: NSSharingService, transitionImageForShareItem item: Any,
                        contentRect: UnsafeMutablePointer<NSRect>) -> NSImage? {
        // The documented nil result disables the source-item transition animation.
        // The chooser should appear at its own position, not fly from the drawer.
        nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        AppLog.event("AirDrop system completion callback")
        finish(sharingService)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let nsError = error as NSError
        finish(sharingService)
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return }
        showError("隔空投送未完成", detail: error.localizedDescription)
    }

    private func finish(_ finished: NSSharingService) {
        guard service === finished else { return }
        service?.delegate = nil
        service = nil
        presentationFrame = .zero
        sharedURLs = []
        fileAccess = nil
    }
}

@MainActor func showError(_ title: String, detail: String) {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: "好")
    alert.runModal()
}

enum AppLog {
    static func event(_ message: String) {
        if CommandLine.arguments.contains("--diagnostics") { NSLog("[AirDropDrawer] %@", message) }
    }
}
