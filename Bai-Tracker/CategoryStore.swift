import UIKit

/// A category definition: a display name + its marker color.
struct CategoryDef {
    let name: String
    let color: UIColor
}

/// Single source of truth for point categories and their colors.
///
/// Merges built-in defaults (mirroring the bundled `category.csv`) with
/// user-added custom categories persisted in `UserDefaults`. Custom categories
/// survive across launches and are available everywhere — the dropdown, the
/// map circles, and the bottom-sheet dots — because `CategoryColors` consults
/// this store.
final class CategoryStore {

    static let shared = CategoryStore()

    private let storageKey = "customCategories"

    /// Built-in defaults (matches `category.csv`). Read-only.
    let defaults: [CategoryDef] = [
        .init(name: "Water", color: .systemBlue),
        .init(name: "Sewer", color: .systemPurple),
        .init(name: "Well",  color: .systemYellow)
    ]

    /// Fixed swatch palette offered when creating a custom category
    /// (the same system colors the existing CSV palette uses).
    static let palette: [UIColor] = [
        .systemBlue, .systemPurple, .systemYellow, .systemRed,
        .systemGreen, .systemOrange, .systemPink, .systemTeal,
        .systemCyan, .systemIndigo, .systemBrown, .systemGray,
        .black, .white
    ]

    /// Fired whenever the set of categories changes (add/remove), so open
    /// pickers can refresh their lists.
    var onChange: (() -> Void)?

    private init() {}

    /// All categories — defaults plus customs — with customs taking
    /// precedence on name collisions (case-insensitive). Order: defaults
    /// first, then customs in insertion order.
    var all: [CategoryDef] {
        var seen = Set<String>()
        var merged: [CategoryDef] = []

        for d in defaults where seen.insert(d.name.lowercased()).inserted {
            merged.append(d)
        }
        for (name, hex) in customs() {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(CategoryDef(name: name, color: UIColor(hex: hex) ?? .systemRed))
        }
        return merged
    }

    /// Resolves a category name to a color, falling back to a red default.
    func color(for name: String?) -> UIColor {
        guard let name, !name.isEmpty else { return .systemRed }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = all.first(where: { $0.name.lowercased() == key }) {
            return match.color
        }
        return .systemRed
    }

    /// Adds (or updates) a custom category and persists it.
    func add(name: String, color: UIColor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var c = customs()
        c[trimmed] = color.toHexString()
        persist(c)
        onChange?()
    }

    /// Removes a custom category by name (defaults cannot be removed).
    func remove(_ name: String) {
        var c = customs()
        c.removeValue(forKey: name)
        c.removeValue(forKey: name) // also clears a differently-cased key below
        for key in c.keys where key.lowercased() == name.lowercased() {
            c.removeValue(forKey: key)
        }
        persist(c)
        onChange?()
    }

    // MARK: - Persistence

    /// Custom categories as name -> hex string, read from UserDefaults.
    private func customs() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func persist(_ customs: [String: String]) {
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - UIColor hex helpers

extension UIColor {
    /// Init from a hex string like "#3366FF" or "3366FF".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8)  & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF)         / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Hex string like "3366FF".
    func toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
