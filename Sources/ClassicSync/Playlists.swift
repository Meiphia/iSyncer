import CryptoKit
import Foundation

public struct LocalPlaylist: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var paths: [String] = []
    public var rules: [PlaylistRule]?
    public var matchAll = true
    public var limit: Int?
    public var sync = true

    public init(name: String, smart: Bool = false) {
        self.name = name
        if smart { rules = [PlaylistRule()] }
    }

    public func members(in songs: [Song]) -> [Song] {
        if let rules {
            let matching = songs.filter { song in
                matchAll ? rules.allSatisfy { $0.matches(song) } : rules.contains { $0.matches(song) }
            }
            return limit.map { Array(matching.prefix(max(0, $0))) } ?? matching
        }
        let byPath = Dictionary(songs.map { (($0.originalSource ?? $0.url).path, $0) }, uniquingKeysWith: { first, _ in first })
        return paths.compactMap { byPath[$0] }
    }

    var deviceID: Data {
        Self.deviceID(id)
    }

    static func deviceID(_ id: UUID) -> Data {
        Data(SHA256.hash(data: Data("iSyncer playlist \(id.uuidString)".utf8)).prefix(8))
    }
}

public struct PlaylistRule: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var field: Field = .artist
    public var operation: Operation = .contains
    public var value = ""

    public init() {}

    public enum Field: String, Codable, CaseIterable, Identifiable, Sendable {
        case title = "Name", artist = "Artist", albumArtist = "Album Artist", album = "Album", genre = "Genre", year = "Year"
        public var id: Self { self }
    }

    public enum Operation: String, Codable, CaseIterable, Identifiable, Sendable {
        case contains = "contains", excludes = "does not contain", equals = "is", starts = "starts with", ends = "ends with"
        public var id: Self { self }
    }

    func matches(_ song: Song) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let candidate: String = switch field {
        case .title: song.title
        case .artist: song.artist
        case .albumArtist: song.albumArtist
        case .album: song.album
        case .genre: song.genre
        case .year: String(song.year)
        }
        let lhs = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let rhs = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        switch operation {
        case .contains: return lhs.contains(rhs)
        case .excludes: return !lhs.contains(rhs)
        case .equals: return lhs == rhs
        case .starts: return lhs.hasPrefix(rhs)
        case .ends: return lhs.hasSuffix(rhs)
        }
    }
}

public struct SyncOptions: Sendable {
    public var playlists: [LocalPlaylist] = []
    public var removedPlaylists: Set<UUID> = []
    public var useAlbumArtistForArtist = false
    public var artwork = false
    public var removeDefaultPlaylists = false
    public var protectedPlaylists: Set<UUID> = []
    public var removedVideoIDs: Set<Data> = []
    public var excludedVideos: [String: String] = [:]
    public var videoExclusionsToSave: [String: String] = [:]
    public var reconcileMusic = false
    public var podcastLimits: [String: PodcastSyncLimit] = [:]
    public var listening: [URL: ClassicListeningState] = [:]
    public var existingListening: [Data: ClassicListeningState] = [:]
    public var expectedListening: [Data: ClassicListeningState]?
    public var matchMusicByPath: Set<URL> = []
    public var fillAlbums: [[Song]] = []
    public var fillReserve: Int64 = 0
    public var episodeCorrections: [EpisodeCorrection] = []
    public var expectedWatchedTVKeys: Set<String>? = nil
    public var expiredTVKeys: Set<String> = []
    public var retainedTVKeys: Set<String> = []
    public var retrySources: Set<URL>? = nil
    public var playedPodcastURLs: Set<URL> = []

    public init() {}
}

public struct PodcastSyncLimit: Sendable {
    let latest: Int
    let pinned: Set<URL>
    let removeOlder: Bool
    let removePlayed: Bool
    let unplayed: Bool
    let hardCap: Bool

    public init(latest: Int, pinned: Set<URL> = [], removeOlder: Bool = true, removePlayed: Bool = false,
                unplayed: Bool = false, hardCap: Bool = false) {
        self.latest = max(0, latest)
        self.pinned = hardCap ? [] : pinned
        self.removeOlder = removeOlder
        self.removePlayed = !hardCap && removePlayed
        self.unplayed = !hardCap && (unplayed || removePlayed)
        self.hardCap = hardCap
    }
}

public final class SyncStop: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    public init() {}
    public func request() { lock.withLock { requested = true } }
    public var isRequested: Bool { lock.withLock { requested } }
}

/// The original transfer identity of a file whose episode numbering changed.
public struct EpisodeTransferIdentity: Sendable {
    public let sources: [URL]
    public let date: Date

    public init(sources: [URL], date: Date) {
        self.sources = sources
        self.date = date
    }

    public func matches(path: String, size: Int) -> Bool {
        sources.contains {
            SyncEngine.transferPath($0, size: size, date: date, kind: .tvShow).caseInsensitiveCompare(path) == .orderedSame
        }
    }
}

public struct EpisodeCorrection: Sendable {
    public let target: URL
    public let season: Int
    public let episode: Int
    public let transfers: [EpisodeTransferIdentity]

    public init(target: URL, season: Int, episode: Int, transfers: [EpisodeTransferIdentity]) {
        self.target = target
        self.season = season
        self.episode = episode
        self.transfers = transfers
    }
}
