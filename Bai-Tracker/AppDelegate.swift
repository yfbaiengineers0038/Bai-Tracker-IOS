import UIKit
import GoogleMaps
import Amplify
import AWSCognitoAuthPlugin
import AWSAPIPlugin
import AWSS3StoragePlugin

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureAmplify()
        GMSServices.provideAPIKey(GoogleAPIConfig.apiKey)

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = LoginViewController()
        window?.makeKeyAndVisible()

        Task { await switchToMapIfSignedIn() }
        return true
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

    private func configureAmplify() {
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.add(plugin: AWSAPIPlugin())
            try Amplify.add(plugin: AWSS3StoragePlugin())
            try Amplify.configure(with: .amplifyOutputs)
        } catch {
            print("Failed to configure Amplify: \(error)")
        }
    }
}
