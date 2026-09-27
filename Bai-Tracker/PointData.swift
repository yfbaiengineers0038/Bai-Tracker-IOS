import UIKit

enum MediaItem {
    case photo(UIImage)
    case video(thumbnail: UIImage, url: URL)

    var thumbnail: UIImage {
        switch self {
        case .photo(let img):          return img
        case .video(let thumb, _):     return thumb
        }
    }
    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
    var videoURL: URL? {
        if case .video(_, let url) = self { return url }
        return nil
    }
}

struct PointData {
    var id: String
    var date: String
    var time: String?
    var location: String?
    var description: String?
    var lat: Double
    var lng: Double
    var photos: [String]
    var timezone: String? = nil
    var comments: [String] = []
    var category: String? = nil
    var projectId: String? = nil
}

/// Converts between a point's stored wall clock and an absolute instant.
///
/// A point's `date`/`time` is the wall-clock reading taken where and when it
/// was created, and `timezone` records which clock that was. That stamp is
/// fixed: every screen shows exactly what was recorded, never re-expressed for
/// wherever the viewer happens to be. The conversion here exists only to move
/// between those stored strings and the `Date` a picker needs.
enum PointTime {

    private static let dateFormat = "yyyy-MM-dd"
    private static let timeFormat = "HH:mm"

    private static func formatter(_ format: String, in zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// The zone a point was created in. Rows written before the app recorded a
    /// zone fall back to the device's, which is what they meant.
    static func recordingZone(_ identifier: String?) -> TimeZone {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return .current }
        return zone
    }

    /// Resolves stored wall-clock strings into the instant they describe.
    /// The date matters: it decides which side of a DST change the time is on.
    static func instant(date: String, time: String?, in zone: TimeZone) -> Date? {
        let clock = time.flatMap { $0.isEmpty ? nil : $0 } ?? "00:00"
        return formatter("\(dateFormat) \(timeFormat)", in: zone).date(from: "\(date) \(clock)")
    }

    /// `HH:mm` for `instant` as read in `zone`.
    static func timeText(_ instant: Date, in zone: TimeZone) -> String {
        formatter(timeFormat, in: zone).string(from: instant)
    }
}

extension PointData {

    /// The instant this point's creation stamp describes. Used to seed the time
    /// picker, which displays it back in `creationZone` so the reading shown is
    /// the one that was recorded.
    var recordedAt: Date? {
        PointTime.instant(date: date, time: time, in: creationZone)
    }

    /// The clock this point's `time` is written on.
    var creationZone: TimeZone {
        PointTime.recordingZone(timezone)
    }
}

protocol PointDetailDelegate: AnyObject {
    func pointDetailDidUpdate(_ point: PointData)
    func pointDetailDidDelete(id: String)
    func pointDetailDidCreate(_ point: PointData)
}
