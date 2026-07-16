import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else {
      return
    }
    guard (try? LocalOnlyDataProtection.prepareApplicationSupportRoots()) != nil else {
      return
    }

    let flutterViewController = FlutterViewController(project: nil, nibName: nil, bundle: nil)
    GeneratedPluginRegistrant.register(with: flutterViewController)
    SecureMeshIosBridge.register(with: flutterViewController.binaryMessenger)
    SecureMeshIosBridge.setForegroundIdleTimerGuard(active: true)

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterViewController
    self.window = window
    window.makeKeyAndVisible()
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    SecureMeshIosBridge.setForegroundIdleTimerGuard(active: true)
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    SecureMeshIosBridge.setForegroundIdleTimerGuard(active: false)
  }
}
