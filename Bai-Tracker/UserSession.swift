import Amplify
import AWSPluginsCore
import Foundation

/// Which Cognito groups the signed-in user belongs to, and what that permits.
///
/// Access is granted per project: each project names a group in its
/// `accessGroup`, and a user sees the projects whose group they're in. `admins`
/// sees everything.
///
/// The backend is the thing that actually enforces this — AppSync filters every
/// query by the groups in the caller's token, so a member physically cannot
/// fetch a project they don't belong to. This type exists so the UI can match:
/// hiding a button the backend would reject is friendlier than showing it and
/// surfacing an authorization error.
///
/// Groups are read from the access token rather than an API call, so this costs
/// nothing and works offline.
@MainActor
final class UserSession {

    static let shared = UserSession()

    /// Bai Engineering staff: every project, every point.
    static let adminGroup = "admins"

    private(set) var groups: [String] = []

    private init() {}

    var isAdmin: Bool { groups.contains(Self.adminGroup) }

    /// Group to stamp on records created in `project` — the project's own
    /// group, so a point lands in exactly the scope its project has.
    ///
    /// The same answer serves admins and members: a member could only have
    /// loaded this project by belonging to its group, and the backend rejects
    /// any other value on create anyway.
    func groupForRecords(in project: Project?) -> String? {
        project?.accessGroup
    }

    /// Reloads groups from the current session. Call after sign-in and on
    /// launch, before showing anything whose contents depend on the role.
    func refresh() async {
        groups = await Self.loadGroups()
    }

    func clear() {
        groups = []
    }

    // MARK: - Token

    private static func loadGroups() async -> [String] {
        guard let session = try? await Amplify.Auth.fetchAuthSession(),
              let provider = session as? AuthCognitoTokensProvider,
              let tokens = try? provider.getCognitoTokens().get() else {
            return []
        }
        return groups(inAccessToken: tokens.accessToken)
    }

    /// Pulls `cognito:groups` out of a JWT payload.
    ///
    /// Reading the token without verifying its signature is fine here: this
    /// only decides what the UI offers, and the token came from our own
    /// keychain. Every request is still authorized server-side.
    static func groups(inAccessToken token: String) -> [String] {
        let segments = token.split(separator: ".")
        guard segments.count >= 2, let payload = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let groups = json["cognito:groups"] as? [String] else {
            return []
        }
        return groups
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url drops the padding that Data(base64Encoded:) requires.
        let remainder = text.count % 4
        if remainder > 0 {
            text += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: text)
    }
}
