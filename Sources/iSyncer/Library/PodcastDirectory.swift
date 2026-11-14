import ClassicSync
import Foundation

struct PodcastShow: Identifiable, Sendable {
    let collectionName: String
    let artistName: String?
    let feedUrl: URL
    var id: URL { feedUrl }
}

enum PodcastDirectory {
    private struct Response: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
    }

    static func search(_ query: String, country: String? = Locale.current.region?.identifier) async throws -> [PodcastShow] {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "itunes.apple.com"
        url.path = "/search"
        url.queryItems = [
            .init(name: "term", value: query),
            .init(name: "media", value: "podcast"),
            .init(name: "entity", value: "podcast"),
            .init(name: "country", value: country ?? "US"),
            .init(name: "limit", value: "30")
        ]
        guard let address = url.url else { throw SyncError("Invalid podcast search.") }
        let (data, response) = try await URLSession.shared.data(from: address)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError("The podcast directory could not complete the search. Try again or enter an RSS link.")
        }
        return try shows(from: data)
    }

    static func shows(from data: Data) throws -> [PodcastShow] {
        var seen: Set<URL> = []
        return try JSONDecoder().decode(Response.self, from: data).results.compactMap { result in
            guard let title = result.collectionName, !title.isEmpty, let feed = result.feedUrl,
                  let url = URL(string: feed), PodcastFeed.isWebURL(url), seen.insert(url).inserted else { return nil }
            return PodcastShow(collectionName: title, artistName: result.artistName, feedUrl: url)
        }
    }
}
