import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneWillResignActive(_ scene: UIScene) {
    UnityAvatarRuntimeBridge.handleSceneLifecycle(.willResignActive)
    super.sceneWillResignActive(scene)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    UnityAvatarRuntimeBridge.handleSceneLifecycle(.didEnterBackground)
    super.sceneDidEnterBackground(scene)
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    UnityAvatarRuntimeBridge.handleSceneLifecycle(.willEnterForeground)
    super.sceneWillEnterForeground(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    UnityAvatarRuntimeBridge.handleSceneLifecycle(.didBecomeActive)
    super.sceneDidBecomeActive(scene)
  }
}
