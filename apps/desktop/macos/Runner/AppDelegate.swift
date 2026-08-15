import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return MacStatusBarPresencePolicy.terminatesAfterLastWindowClosed
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MacStatusBarPresence.shared.prepareToTerminate()
    return super.applicationShouldTerminate(sender)
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    MacStatusBarPresence.shared.restoreMainWindow()
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The shell draws its own chrome under a hidden title bar. Keep the system
    // title-bar double-click action (zoom / minimize / fill) from firing inside
    // that Flutter chrome; the shell offers zoom deliberately on its top bar.
    UserDefaults.standard.register(defaults: ["AppleActionOnDoubleClick": "None"])
    super.applicationDidFinishLaunching(notification)
    let window = mainFlutterWindow ?? NSApp.windows.first { $0 is MainFlutterWindow }
    guard let window else { return }
    if MacStatusBarPresencePolicy.createsStatusItemAtLaunch {
      MacStatusBarPresence.shared.attach(mainWindow: window)
    }
    if MacStatusBarPresencePolicy.shouldSilentStart(arguments: CommandLine.arguments) {
      MacStatusBarPresence.shared.hideToStatusBar(window)
      // Flutter may order the window front on the first frame after launch.
      DispatchQueue.main.async {
        MacStatusBarPresence.shared.hideToStatusBar(window)
      }
    } else {
      window.makeKeyAndOrderFront(nil)
    }
  }
}
