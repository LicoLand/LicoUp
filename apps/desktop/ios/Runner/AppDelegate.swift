import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SecureMeshIosBridge.setForegroundIdleTimerGuard(active: true)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    SecureMeshIosBridge.setForegroundIdleTimerGuard(active: true)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    SecureMeshIosBridge.setForegroundIdleTimerGuard(active: false)
  }
}
