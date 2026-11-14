import ClassicSync
import Foundation

enum VideoDirectory {
    struct Match: Codable, Identifiable {
        let id: Int
        let title: String?
        let name: String?
        let overview: String?
        let releaseDate: String?
        let firstAirDate: String?
        let airDate: String?
        let posterPath: String?
        let stillPath: String?
        let episodeNumber: Int?

        var displayTitle: String { title ?? name ?? "Untitled" }
        var year: String { String((releaseDate ?? firstAirDate ?? "").prefix(4)) }
        var poster: URL? { VideoDirectory.imageURL(posterPath) }
    }

    private struct Results: Decodable { let results: [Match] }
    private struct Season: Decodable {
        let episodes: [Match]
        let posterPath: String?
    }

    struct EpisodeUpdate: Identifiable {
        let video: VideoItem
        let metadata: VideoMetadataEdit?
        var id: VideoItem.ID { video.id }
    }
    static let tokenAccount = "TMDB API Read Access Token"

    static func search(_ query: String, tv: Bool, token: String) async throws -> [Match] {
        let result: Results = try await request("/3/search/" + (tv ? "tv" : "movie"),
                                                query: [.init(name: "query", value: query)], token: token)
        return result.results
    }

    static func metadata(for match: Match, episode: (season: Int, number: Int)?,
                         token: String) async throws -> (VideoMetadataEdit, Bool) {
        let details: Match
        if let episode {
            details = try await request("/3/tv/\(match.id)/season/\(episode.season)/episode/\(episode.number)", token: token)
        } else {
            details = match
        }
        let imageURLs = [match.poster, imageURL(details.stillPath)].compactMap { $0 }
        let artwork = try await firstArtwork(imageURLs)
        return (edit(for: details, artwork: artwork), !imageURLs.isEmpty && artwork == nil)
    }

    static func episodeUpdates(for match: Match, videos: [VideoItem], token: String,
                               session: URLSession = .shared) async throws -> [EpisodeUpdate] {
        var updates: [EpisodeUpdate] = []
        var artworkCache: [URL: Data] = [:]
        var attempted = Set<URL>()
        let bySeason = Dictionary(grouping: videos, by: \.season)
        for season in bySeason.keys.sorted() {
            try Task.checkCancellation()
            guard let local = bySeason[season] else { continue }
            let numbered = local.filter { $0.episode > 0 }
            let remote: Season? = numbered.isEmpty || season < 0 ? nil
                : try await request("/3/tv/\(match.id)/season/\(season)", token: token, missingIsNil: true, session: session)
            let episodes = Dictionary((remote?.episodes ?? []).compactMap { item in
                item.episodeNumber.map { ($0, item) }
            }, uniquingKeysWith: { first, _ in first })
            let posters = [imageURL(remote?.posterPath), match.poster].compactMap { $0 }
            for video in local.sorted(by: { ($0.episode, $0.id) < ($1.episode, $1.id) }) {
                guard video.episode > 0, let details = episodes[video.episode] else {
                    updates.append(EpisodeUpdate(video: video, metadata: nil))
                    continue
                }
                var artwork: Data?
                for url in posters + [imageURL(details.stillPath)].compactMap({ $0 }) {
                    if attempted.insert(url).inserted { artworkCache[url] = try await firstArtwork([url]) }
                    if let cached = artworkCache[url] {
                        artwork = cached
                        break
                    }
                }
                updates.append(EpisodeUpdate(video: video, metadata: edit(for: details, artwork: artwork)))
            }
        }
        return updates
    }

    private static func edit(for details: Match, artwork: Data?) -> VideoMetadataEdit {
        let date = (details.airDate ?? details.releaseDate).flatMap { value in
            ISO8601DateFormatter().date(from: value + "T00:00:00Z")
        }
        let overview = details.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VideoMetadataEdit(title: details.title ?? details.name, releaseDate: date, artwork: artwork,
                                 overview: overview.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func firstArtwork(_ urls: [URL]) async throws -> Data? {
        for url in urls {
            try Task.checkCancellation()
            if let data = try? await image(at: url), VideoMetadataEdit.isValidArtwork(data) { return data }
        }
        try Task.checkCancellation()
        return nil
    }

    private static func imageURL(_ path: String?) -> URL? {
        guard let path, path.range(of: #"^/[A-Za-z0-9_.-]+\.(jpg|png)$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500" + path)
    }

    private static func image(at url: URL) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError("Could not download the artwork.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8_388_608 else { throw SyncError("The artwork exceeds 8 MB.") }
            data.append(byte)
        }
        return data
    }

    private static func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> T {
        guard let result: T = try await request(path, query: query, token: token, missingIsNil: false) else {
            throw SyncError("TMDB returned an empty response.")
        }
        return result
    }

    private static func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], token: String,
                                              missingIsNil: Bool, session: URLSession = .shared) async throws -> T? {
        var address = URLComponents()
        address.scheme = "https"
        address.host = "api.themoviedb.org"
        address.path = path
        if !query.isEmpty { address.queryItems = query }
        guard let url = address.url else { throw SyncError("Invalid TMDB request.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError("TMDB returned an invalid response.") }
        switch http.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        case 401, 403: throw SyncError("TMDB rejected the API Read Access Token.")
        case 404 where missingIsNil: return nil
        case 404: throw SyncError("TMDB has no entry for that season and episode.")
        case 429: throw SyncError("TMDB is rate limiting requests. Try again in a moment.")
        default: throw SyncError("TMDB could not complete the request (HTTP \(http.statusCode)).")
        }
    }
}
