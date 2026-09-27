import UIKit
import Amplify

/// Owns the app's single window. Apps built with the current SDK must adopt the
/// UIScene life cycle or they refuse to launch, so window setup lives here
/// instead of in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = LoginViewController()
        window.makeKeyAndVisible()
        self.window = window

        Task { await switchToMapIfSignedIn() }
    }

    /// Anything the queue couldn't finish — a force-quit, a dead uplink, a
    /// crash — gets another go whenever the app comes back to the foreground.
    func sceneDidBecomeActive(_ scene: UIScene) {
        UploadQueue.shared.start()
    }

    private func switchToMapIfSignedIn() async {
        guard let session = try? await Amplify.Auth.fetchAuthSession(),
              session.isSignedIn else { return }

        // Cognito restores its keychain session on every launch. If the user
        // didn't ask to be remembered, drop it here so they land on the login
        // screen instead of being signed in behind their back.
        guard LoginPreferences.rememberMe else {
            _ = await Amplify.Auth.signOut()
            return
        }

        // Groups decide what the project picker and map offer, so load them
        // before either appears.
        await UserSession.shared.refresh()

        await MainActor.run {
            if ProjectStore.shared.current != nil {
                // Returning user with a remembered project → straight to the map.
                window?.rootViewController = ViewController()
            } else {
                // No project chosen yet → land on the picker as a gate.
                let picker = ProjectPickerViewController()
                picker.isGate = true
                let nav = UINavigationController(rootViewController: picker)
                nav.modalPresentationStyle = .fullScreen
                window?.rootViewController = nav
            }
        }
    }
}
