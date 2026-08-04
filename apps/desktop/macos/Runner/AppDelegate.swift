import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The shell draws its own chrome under a hidden title bar. Keep the system
    // title-bar double-click action (zoom / minimize / fill) from firing inside
    // that Flutter chrome; the shell offers zoom deliberately on its top bar.
    UserDefaults.standard.register(defaults: ["AppleActionOnDoubleClick": "None"])
    super.applicationDidFinishLaunching(notification)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }
}
