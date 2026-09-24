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

protocol PointDetailDelegate: AnyObject {
    func pointDetailDidUpdate(_ point: PointData)
    func pointDetailDidDelete(id: String)
    func pointDetailDidCreate(_ point: PointData)
}
