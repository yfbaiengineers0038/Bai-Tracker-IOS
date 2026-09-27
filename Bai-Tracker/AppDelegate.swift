import UIKit
import GoogleMaps
import Amplify
import AWSCognitoAuthPlugin
import AWSAPIPlugin
import AWSS3StoragePlugin

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureAmplify()
        GMSServices.provideAPIKey(GoogleAPIConfig.apiKey)
        return true
    }

    /// iOS finishes background transfers out of process and then wakes the app
    /// to hand back the results. Without this the S3 plugin never learns that
    /// an upload completed while we were suspended, so the bytes sit in the
    /// bucket with no point referencing them.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task {
            _ = await Amplify.Storage.handleBackgroundEvents(identifier: identifier)
            await MainActor.run { completionHandler() }
        }
    }

    // The window and its root view controller belong to `SceneDelegate`; UIKit
    // asks for a configuration here rather than reading one from Info.plist.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
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
