import CryptoKit
import Foundation

actor LyricsLookup {
    static let shared = LyricsLookup()

    struct Query: Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Double

        init(_ track: Track) {
            title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            self.artist = artist.isEmpty ? track.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines) : artist
            album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            duration = track.duration.isFinite && track.duration > 0 ? track.duration.rounded() : 0
        }

        var canSearch: Bool { !title.isEmpty && !artist.isEmpty }

        var cacheFile: URL {
            let key = [title, artist, album, String(duration)].joined(separator: "\u{1f}")
            let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return URL.cachesDirectory.appending(path: "com.jaz.isyncer/Lyrics/\(hash).json")
        }
    }

    enum Failure: LocalizedError {
        case unavailable, rateLimited

        var errorDescription: String? {
            switch self {
            case .unavailable: "Couldn’t reach LRCLIB. Try again in a moment."
            case .rateLimited: "LRCLIB is busy. Try again in a moment."
            }
        }
    }

    private struct Result: Codable {
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    func cached(_ query: Query) -> Lyrics? {
        guard query.canSearch, let data = try? Data(contentsOf: query.cacheFile),
              let result = try? JSONDecoder().decode(Result.self, from: data) else { return nil }
        return Self.lyrics(for: result, query: query)
    }

    func find(_ query: Query) async throws -> Lyrics? {
        guard query.canSearch else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            .init(name: "track_name", value: query.title),
            .init(name: "artist_name", value: query.artist)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5"
        request.setValue("iSyncer/\(version) (com.jaz.isyncer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        if http.statusCode == 429 { throw Failure.rateLimited }
        guard http.statusCode == 200 else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw Failure.unavailable }
            data.append(byte)
        }
        let results = try JSONDecoder().decode([Result].self, from: data)
        guard let match = Self.bestMatch(in: results, query: query) else { return nil }
        try Task.checkCancellation()
        if let data = try? JSONEncoder().encode(match.result) {
            try? FileManager.default.createDirectory(at: query.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: query.cacheFile, options: .atomic)
        }
        return match.lyrics
    }

    private static func bestMatch(in results: [Result], query: Query) -> (result: Result, lyrics: Lyrics)? {
        let title = normalize(query.title)
        let artist = normalize(query.artist)
        let album = normalize(query.album)
        let matches = results.compactMap { result -> (result: Result, lyrics: Lyrics)? in
            guard normalize(result.trackName) == title, normalize(result.artistName) == artist,
                  let lyrics = lyrics(for: result, query: query) else { return nil }
            return (result, lyrics)
        }
        return matches.min { first, second in
            let a = first.result, b = second.result
            let scoreA = (first.lyrics.timed.isEmpty, album.isEmpty || normalize(a.albumName ?? "") != album)
            let scoreB = (second.lyrics.timed.isEmpty, album.isEmpty || normalize(b.albumName ?? "") != album)
            if scoreA.0 != scoreB.0 { return !scoreA.0 }
            if scoreA.1 != scoreB.1 { return !scoreA.1 }
            return distance(a.duration, query.duration) < distance(b.duration, query.duration)
        }
    }

    private static func lyrics(for result: Result, query: Query) -> Lyrics? {
        guard result.instrumental != true else { return nil }
        let parsed = bounded(result.syncedLyrics).map(Lyrics.parse)
        let close = distance(result.duration, query.duration) <= 5
        let timed = close ? parsed?.timed ?? [] : []
        let plain = bounded(result.plainLyrics) ?? parsed?.plain ?? ""
        guard !timed.isEmpty || !plain.isEmpty else { return nil }
        return Lyrics(plain: plain, timed: timed)
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value, value.utf8.count <= Lyrics.maximumSize else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func distance(_ duration: Double?, _ target: Double) -> Double {
        guard let duration, duration > 0, target > 0 else { return .infinity }
        return abs(duration - target)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
