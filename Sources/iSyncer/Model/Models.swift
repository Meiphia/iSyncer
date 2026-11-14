import Foundation

struct Track: Codable, Identifiable, Hashable, Sendable {
    /// Path relative to the library root — stable as long as the file doesn't move.
    var id: String
    var size: Int64
    var modified: Double
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var year: Int
    var trackNumber: Int
    var discNumber: Int
    var duration: Double
    var codec: String
    var bitrate: Int
    var sampleRate: Int
    var lossless: Bool
    var playCount: Int
    var lastPlayed: Double
    var dateAdded: Double
    /// My Rating, 0–5 stars.
    var rating: Int = 0
    var resumePosition: Double? = nil
    var finishedListening: Bool? = nil
    /// ReplayGain from the file's tags or iSyncer's own loudness analysis (dB; peaks linear).
    var rgTrackGain: Double?
    var rgAlbumGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumPeak: Double?

    var fileExtension: String { (id as NSString).pathExtension.lowercased() }
    var displayAlbumArtist: String { albumArtist.isEmpty ? artist : albumArtist }
    var kind: String { lossless ? "\(codec) (lossless)" : codec }

    init(id: String, size: Int64, modified: Double, info: TagInfo, dateAdded: Double) {
        self.id = id
        self.size = size
        self.modified = modified
        self.title = info.title
        self.artist = info.artist
        self.albumArtist = info.albumArtist
        self.album = info.album
        self.genre = info.genre
        self.year = info.year
        self.trackNumber = info.track
        self.discNumber = info.disc
        self.duration = info.duration
        self.codec = info.codec
        self.bitrate = info.bitrate
        self.sampleRate = info.sampleRate
        self.lossless = info.lossless
        self.playCount = 0
        self.lastPlayed = 0
        self.dateAdded = dateAdded
        self.rgTrackGain = info.rgTrackGain
        self.rgAlbumGain = info.rgAlbumGain
        self.rgTrackPeak = info.rgTrackPeak
        self.rgAlbumPeak = info.rgAlbumPeak
    }

    /// Re-applies tags after the file changed, keeping play history.
    mutating func update(from info: TagInfo, size: Int64, modified: Double) {
        let plays = playCount, last = lastPlayed, added = dateAdded, stars = rating
        let old = self
        self = Track(id: id, size: size, modified: modified, info: info, dateAdded: added)
        playCount = plays
        lastPlayed = last
        rating = stars
        resumePosition = old.resumePosition
        finishedListening = old.finishedListening
        // Keep measured loudness if the file has no ReplayGain tags of its own.
        if rgTrackGain == nil {
            rgTrackGain = old.rgTrackGain; rgTrackPeak = old.rgTrackPeak
            rgAlbumGain = old.rgAlbumGain; rgAlbumPeak = old.rgAlbumPeak
        }
    }

    // Tolerant decoding so new fields don't break saved libraries.
    enum CodingKeys: String, CodingKey {
        case id, size, modified, title, artist, albumArtist, album, genre, year, trackNumber, discNumber
        case duration, codec, bitrate, sampleRate, lossless, playCount, lastPlayed, dateAdded, rating
        case rgTrackGain, rgAlbumGain, rgTrackPeak, rgAlbumPeak, resumePosition, finishedListening
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        modified = try c.decodeIfPresent(Double.self, forKey: .modified) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        year = try c.decodeIfPresent(Int.self, forKey: .year) ?? 0
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? ""
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 0
        lossless = try c.decodeIfPresent(Bool.self, forKey: .lossless) ?? false
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try c.decodeIfPresent(Double.self, forKey: .lastPlayed) ?? 0
        dateAdded = try c.decodeIfPresent(Double.self, forKey: .dateAdded) ?? 0
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        resumePosition = try c.decodeIfPresent(Double.self, forKey: .resumePosition)
        finishedListening = try c.decodeIfPresent(Bool.self, forKey: .finishedListening)
        rgTrackGain = try c.decodeIfPresent(Double.self, forKey: .rgTrackGain)
        rgAlbumGain = try c.decodeIfPresent(Double.self, forKey: .rgAlbumGain)
        rgTrackPeak = try c.decodeIfPresent(Double.self, forKey: .rgTrackPeak)
        rgAlbumPeak = try c.decodeIfPresent(Double.self, forKey: .rgAlbumPeak)
    }
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var trackIDs: [String]
    /// Library-relative path of an .m3u/.m3u8 this playlist mirrors; nil for playlists made in the app.
    var importedFrom: String?

    var isImported: Bool { importedFrom != nil }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "35,012 songs, 98.2 days, 812 GB"
    static func summary(count: Int, seconds: Double, bytes size: Int64, item: String = "song") -> String {
        let countLabel = "\(count.formatted()) \(item)\(count == 1 ? "" : "s")"
        let time: String
        if seconds >= 86400 { time = String(format: "%.1f days", seconds / 86400) }
        else if seconds >= 3600 { time = String(format: "%.1f hours", seconds / 3600) }
        else { time = String(format: "%.0f minutes", seconds / 60) }
        return "\(countLabel), \(time), \(bytes(size))"
    }
}

/// A video file, described by its folder layout (videos rarely carry useful tags).
struct VideoItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case tv, movie, other }

    /// Path relative to the videos root.
    var id: String
    var size: Int64
    var modified: Double
    var kind: Kind
    var show: String
    var season: Int
    var episode: Int
    var title: String
    var year: Int

    var fileExtension: String { (id as NSString).pathExtension.lowercased() }

    var kindLabel: String {
        switch kind {
        case .tv: return "TV"
        case .movie: return "Movie"
        case .other: return "Other"
        }
    }

    var displayTitle: String {
        switch kind {
        case .tv: return episode > 0 ? "\(episode). \(title)" : title
        case .movie: return year > 0 ? "\(title) (\(year))" : title
        case .other: return title
        }
    }


}
