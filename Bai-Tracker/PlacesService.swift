import Foundation

/// The Google API key shared by the Maps SDK and the Places endpoints.
///
/// The value lives in the git-ignored `Secrets.swift`; swapping keys is a
/// one-line change there. See `REBUILD.md` for setup.
enum GoogleAPIConfig {
    static let apiKey = Secrets.googleAPIKey
}

/// A single autocomplete prediction — what a search row displays.
struct PlaceSuggestion {
    let placeID: String
    /// The place itself, e.g. "Raleigh Union Station".
    let primaryText: String
    /// Disambiguating context, e.g. "510 W Martin St, Raleigh, NC, USA".
    let secondaryText: String
}

/// A place resolved to coordinates, ready to anchor a project on.
struct PlaceLocation {
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
}

enum PlacesServiceError: LocalizedError {
    case badURL
    case http(status: Int, message: String)
    case malformedResponse
    /// The place had no coordinates, so it can't center a project.
    case missingLocation

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Couldn't build the Places request."
        case .http(_, let message):
            return message
        case .malformedResponse:
            return "Unexpected response from Google Places."
        case .missingLocation:
            return "That place has no coordinates. Try another."
        }
    }
}

/// Thin client over the Google Places API (New) REST endpoints.
///
/// REST rather than the GooglePlaces SDK so the app doesn't take on another
/// package dependency — only the Maps SDK is linked, and the same API key
/// authorizes both.
struct PlacesService {

    /// Groups one user's keystrokes into a single billable autocomplete
    /// session. Google bills per session, so keep one service instance per
    /// search screen and pass the same token through to `details`.
    private let sessionToken = UUID().uuidString

    private static let host = "https://places.googleapis.com/v1"

    /// Predictions for a partial query, optionally biased toward a map area
    /// so nearby places rank first.
    func autocomplete(
        _ input: String,
        near bias: (latitude: Double, longitude: Double)? = nil
    ) async throws -> [PlaceSuggestion] {

        struct Center: Encodable { let latitude: Double; let longitude: Double }
        struct Circle: Encodable { let center: Center; let radius: Double }
        struct LocationBias: Encodable { let circle: Circle }
        struct Body: Encodable {
            let input: String
            let sessionToken: String
            let locationBias: LocationBias?
        }

        struct TextValue: Decodable { let text: String }
        struct StructuredFormat: Decodable {
            let mainText: TextValue?
            let secondaryText: TextValue?
        }
        struct PlacePrediction: Decodable {
            let placeId: String
            let text: TextValue?
            let structuredFormat: StructuredFormat?
        }
        struct Suggestion: Decodable { let placePrediction: PlacePrediction? }
        struct Response: Decodable { let suggestions: [Suggestion]? }

        let locationBias = bias.map {
            // 50 km is the maximum radius the endpoint accepts.
            LocationBias(circle: Circle(
                center: Center(latitude: $0.latitude, longitude: $0.longitude),
                radius: 50_000))
        }

        var request = try makeRequest(path: "places:autocomplete", method: "POST")
        request.httpBody = try JSONEncoder().encode(
            Body(input: input, sessionToken: sessionToken, locationBias: locationBias))

        let response: Response = try await send(request)
        return (response.suggestions ?? []).compactMap { suggestion in
            guard let prediction = suggestion.placePrediction else { return nil }
            // `structuredFormat` splits name from address; `text` is the whole
            // line and covers predictions that arrive without the split.
            let primary = prediction.structuredFormat?.mainText?.text
                ?? prediction.text?.text
                ?? ""
            guard !primary.isEmpty else { return nil }
            return PlaceSuggestion(
                placeID: prediction.placeId,
                primaryText: primary,
                secondaryText: prediction.structuredFormat?.secondaryText?.text ?? "")
        }
    }

    /// Resolves a prediction into a name, address, and coordinates.
    func details(placeID: String) async throws -> PlaceLocation {
        struct LatLng: Decodable { let latitude: Double; let longitude: Double }
        struct TextValue: Decodable { let text: String }
        struct Response: Decodable {
            let displayName: TextValue?
            let formattedAddress: String?
            let location: LatLng?
        }

        var request = try makeRequest(path: "places/\(placeID)", method: "GET")
        // Field masks are mandatory on this endpoint and cap what's billed.
        request.setValue("displayName,formattedAddress,location",
                         forHTTPHeaderField: "X-Goog-FieldMask")

        let response: Response = try await send(request)
        guard let location = response.location else {
            throw PlacesServiceError.missingLocation
        }
        return PlaceLocation(
            name: response.displayName?.text ?? "",
            address: response.formattedAddress ?? "",
            latitude: location.latitude,
            longitude: location.longitude)
    }

    // MARK: - Transport

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "\(Self.host)/\(path)") else {
            throw PlacesServiceError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GoogleAPIConfig.apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // Lets an API key restricted to this iOS app authorize the call.
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PlacesServiceError.http(status: status,
                                          message: Self.message(fromError: data, status: status))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlacesServiceError.malformedResponse
        }
    }

    /// Surfaces Google's own explanation (e.g. "This API ... is not enabled")
    /// instead of a bare status code, since that's what points at the fix.
    private static func message(fromError data: Data, status: Int) -> String {
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            return failure.error.message
        }
        return "Google Places request failed (HTTP \(status))."
    }
}
