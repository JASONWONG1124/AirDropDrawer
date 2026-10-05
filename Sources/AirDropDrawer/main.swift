import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--self-check") { exit(runNativeChecks()) }
let delegate = AppDelegate()
app.delegate = delegate
app.run()
