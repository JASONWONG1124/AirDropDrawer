import AppKit
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = DragMonitor()
    private let airDrop = AirDropCoordinator()
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services normally reuses the app; direct binary launches get the same guard.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) { NSApp.terminate(nil); return }
        monitor.onDrop = { [weak self] files, source in self?.airDrop.share(files, from: source) }
        setupMenu()
        monitor.start()
        AppLog.event("application ready")
        #if DEBUG
        if CommandLine.arguments.contains("--long-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.monitor.preview(duration: 180) }
        }
        #endif
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.monitor.preview() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--share-test-file"),
           CommandLine.arguments.indices.contains(index + 1), let source = monitor.panels.first {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                source.disarm()
                self?.airDrop.share([url], from: source)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        monitor.preview()
        return false
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "airdrop", accessibilityDescription: "AirDrop 抽屉")
            ?? NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "AirDrop 抽屉")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "AirDrop 抽屉 · 顶部暂存 · 拖出使用 · AirDrop"
        item.button?.setAccessibilityLabel("AirDrop 抽屉")
        let menu = NSMenu()
        menu.delegate = self
        let heading = NSMenuItem(title: "AirDrop 抽屉 · 0.4.1", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        menu.addItem(menuItem("打开暂存区", action: #selector(preview), key: "p"))
        let pause = menuItem("暂停自动展开与接收", action: #selector(togglePause))
        menu.addItem(pause); pauseItem = pause
        let login = menuItem("登录时启动", action: #selector(toggleLogin))
        menu.addItem(login); loginItem = login
        menu.addItem(.separator())
        menu.addItem(menuItem("使用说明", action: #selector(showHelp)))
        menu.addItem(menuItem("退出 AirDrop 抽屉", action: #selector(quit), key: "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem?.state = monitor.paused ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func preview() {
        // Run after the menu has closed so it doesn't cover the preview.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.monitor.preview() }
    }

    @objc private func togglePause() { monitor.paused.toggle() }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch { showError("无法更改登录启动设置", detail: error.localizedDescription) }
    }

    @objc private func showHelp() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "顶部暂存，随时拖出"
        alert.informativeText = "把文件拖到顶部中央，左侧可隔空投送，右侧可暂存文件。切回目标应用后，把鼠标移到顶部中央停留片刻，再把暂存文件拖出去。\n\n暂存只记录原文件的引用。拖出后仍保留，单个移除或清空不会删除原文件；退出本应用后清空。原文件被删除或所在磁盘断开后无法使用，请重新拖入。\n\n支持桌面和 Finder 中的本地文件、文件夹。空闲时抽屉隐藏，菜单栏也可打开暂存区。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
