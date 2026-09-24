import UIKit

/// A backend Project: the scope a Point belongs to (Lawrence's schema change).
/// Each Point must carry a `projectId`; the app reads the selected project
/// from here and feeds it into list/create queries.
struct Project: Codable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let zoom: Double
}

/// Holds the currently-selected project, persisted in `UserDefaults` so a
/// returning user lands back in their project without re-picking.
///
/// Mirrors the `CategoryStore` pattern: a shared singleton + an `onChange`
/// notifier so the map can reload when the project switches.
final class ProjectStore {

    static let shared = ProjectStore()

    private let storageKey = "selectedProject"

    /// Fired whenever the selected project changes, so observers (the map)
    /// can reload points and re-center the camera.
    var onChange: (() -> Void)?

    private init() {}

    /// The currently-selected project, or nil if none chosen yet.
    var current: Project? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Project.self, from: data)
    }

    /// Persists the selection and notifies observers.
    func setCurrent(_ project: Project) {
        if let data = try? JSONEncoder().encode(project) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        onChange?()
    }

    /// Clears the selection (e.g. on logout).
    func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        onChange?()
    }
}
