import UIKit

/// Resolves a point's `category` to a marker color, driven by the bundled
/// `category.csv` dataset (columns: `Category,Color`).
///
/// The CSV is parsed once, lazily. Categories and color names are matched
/// case-insensitively. Any category not present in the CSV — or a point with
/// no category at all — falls back to `fallbackColor`.
enum CategoryColors {

    /// Color used when a point's category is missing or not listed in the CSV.
    static let fallbackColor: UIColor = .systemRed

    // MARK: - Public API

    /// Color for a category name, e.g. "Water" -> blue.
    ///
    /// Resolution order: custom/built-in categories in `CategoryStore` first
    /// (covers user-added categories + their colors), then the bundled CSV
    /// table, then `fallbackColor`.
    static func color(for category: String?) -> UIColor {
        if let key = normalized(category) {
            // CategoryStore merges defaults + user customs.
            let storeColor = CategoryStore.shared.color(for: category)
            // The store returns red for unknowns; only trust it when the name
            // actually resolves to a known category.
            if CategoryStore.shared.all.contains(where: { $0.name.lowercased() == key }) {
                return storeColor
            }
            if let color = table[key] { return color }
        }
        return fallbackColor
    }

    /// A cached circular marker icon tinted with the category's color.
    static func markerIcon(for category: String?) -> UIImage {
        let key = normalized(category) ?? ""
        if let cached = iconCache[key] { return cached }
        let icon = makeDot(color: color(for: category))
        iconCache[key] = icon
        return icon
    }

    // MARK: - CSV loading

    /// category (normalized) -> color, parsed from `category.csv`.
    private static let table: [String: UIColor] = loadTable()

    private static var iconCache: [String: UIImage] = [:]

    private static func loadTable() -> [String: UIColor] {
        guard let url = Bundle.main.url(forResource: "category", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var result: [String: UIColor] = [:]
        // Split on any newline flavor; skip the header row.
        let rows = text.split(whereSeparator: \.isNewline)
        for row in rows.dropFirst() {
            let cols = row.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2 else { continue }
            let category = cols[0].trimmingCharacters(in: .whitespaces).lowercased()
            let colorName = cols[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard !category.isEmpty, let color = namedColor(colorName) else { continue }
            result[category] = color
        }
        return result
    }

    private static func normalized(_ category: String?) -> String? {
        guard let key = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else { return nil }
        return key
    }

    /// Maps CSV color names to concrete colors. Unknown names return nil so the
    /// row is skipped and the point falls back to `fallbackColor`.
    private static func namedColor(_ name: String) -> UIColor? {
        switch name {
        case "blue":         return .systemBlue
        case "purple":       return .systemPurple
        case "yellow":       return .systemYellow
        case "red":          return .systemRed
        case "green":        return .systemGreen
        case "orange":       return .systemOrange
        case "pink":         return .systemPink
        case "teal":         return .systemTeal
        case "cyan":         return .systemCyan
        case "indigo":       return .systemIndigo
        case "brown":        return .systemBrown
        case "gray", "grey": return .systemGray
        case "black":        return .black
        case "white":        return .white
        default:             return nil
        }
    }

    // MARK: - Icon rendering

    private static func makeDot(color: UIColor) -> UIImage {
        let size: CGFloat = 14
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}
