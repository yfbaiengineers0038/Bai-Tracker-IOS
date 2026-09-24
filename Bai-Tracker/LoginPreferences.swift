import Foundation

/// Remembers the sign-in choices a returning user made on this device.
///
/// Cognito already persists its session in the keychain, so the app would stay
/// signed in indefinitely on its own. This store turns that into an explicit,
/// opt-out choice: when `rememberMe` is false, `AppDelegate` drops the restored
/// session on the next launch and the user has to sign in again.
enum LoginPreferences {

    private static let rememberMeKey = "rememberMeOnThisDevice"
    private static let rememberedEmailKey = "rememberedEmail"

    /// Whether to keep the user signed in between launches.
    ///
    /// Defaults to true — the app's existing behavior — so upgrading users
    /// aren't suddenly signed out.
    static var rememberMe: Bool {
        get { UserDefaults.standard.object(forKey: rememberMeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rememberMeKey) }
    }

    /// The last email signed in with, so the field can be prefilled. Only kept
    /// while `rememberMe` is on. Never stores the password — Cognito's keychain
    /// session is what avoids the re-login, so there's nothing to gain from it.
    static var rememberedEmail: String? {
        get { UserDefaults.standard.string(forKey: rememberedEmailKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: rememberedEmailKey)
            } else {
                UserDefaults.standard.removeObject(forKey: rememberedEmailKey)
            }
        }
    }

    /// Records the choice made on a successful sign-in.
    static func record(rememberMe remember: Bool, email: String) {
        rememberMe = remember
        rememberedEmail = remember ? email : nil
    }
}
