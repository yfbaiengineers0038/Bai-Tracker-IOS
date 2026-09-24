import Foundation

struct Point: Identifiable, Codable {
    var id: String
    var date: String
    var time: String?
    var location: String?
    var lng: Double
    var lat: Double
    var description: String?
    var photos: [String]?
    var timezone: String?
    var comments: [String]?
    var category: String?
    var projectId: String?
    var createdAt: String?
    var updatedAt: String?
}
