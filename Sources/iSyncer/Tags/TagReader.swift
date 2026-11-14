import Foundation

/// Everything the library cares about from one audio file.
struct TagInfo: Sendable {
    var title = ""
    var artist = ""
    var albumArtist = ""
    var album = ""
    var genre = ""
    var year = 0
    var track = 0
    var disc = 0
    var duration: Double = 0
    var bitrate = 0          // kbps
    var sampleRate = 0
    var codec = ""
    var lossless = false
    var artwork: Data?
    // Read for Get Info; not stored in the library.
    var lyrics: String?
    var timedLyrics: [Lyrics.Line] = []
    var composer = ""
    var grouping = ""
    var comment = ""
    var bpm = 0
    var trackTotal = 0
    var discTotal = 0
    var compilation = false
    // ReplayGain (dB gains, linear peaks)
    var rgTrackGain: Double?
    var rgAlbumGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumPeak: Double?
}

/// Dependency-free tag readers. They only read headers (and the file tail for Ogg/MP3v1),
/// so scanning tens of thousands of files stays fast.
enum TagReader {
    static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "m4b", "mp4", "aac", "alac", "ogg", "oga", "opus", "wav", "aif", "aiff"]
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]
    static let lossyCodecs: Set<String> = ["MP3", "AAC", "Vorbis", "Opus"]

    static func read(url: URL, wantArtwork: Bool = false) -> TagInfo? {
        guard let file = FileReader(url: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        var info: TagInfo?
        switch ext {
        case "mp3":
            info = MP3Reader.read(file, wantArtwork: wantArtwork)
        case "flac":
            info = FLACReader.read(file, wantArtwork: wantArtwork)
        case "m4a", "m4b", "mp4", "aac", "alac":
            info = MP4Reader.read(file, wantArtwork: wantArtwork)
        case "ogg", "oga", "opus":
            info = OggReader.read(file, wantArtwork: wantArtwork)
        case "wav":
            info = RIFFReader.readWAV(file, wantArtwork: wantArtwork)
        case "aif", "aiff":
            info = RIFFReader.readAIFF(file, wantArtwork: wantArtwork)
        default:
            return nil
        }
        guard var result = info else { return nil }
        if result.bitrate == 0, result.duration > 0 {
            result.bitrate = Int(Double(file.size) * 8 / result.duration / 1000)
        }
        fillFromPath(&result, url: url)
        return result
    }

    /// Libraries organised as Artist/Album/NN Title.ext still look right when tags are missing.
    private static func fillFromPath(_ info: inout TagInfo, url: URL) {
        let parts = url.deletingPathExtension().pathComponents
        if info.title.isEmpty {
            var name = url.deletingPathExtension().lastPathComponent
            // "01 - Title" / "01. Title" / "01 Title"
            if let range = name.range(of: #"^\d{1,3}[\s.\-_]+"#, options: .regularExpression) {
                if info.track == 0 { info.track = Int(name[range].filter(\.isNumber)) ?? 0 }
                name.removeSubrange(range)
            }
            info.title = name
        }
        if info.album.isEmpty, parts.count >= 2 { info.album = parts[parts.count - 2] }
        if info.artist.isEmpty, parts.count >= 3 { info.artist = parts[parts.count - 3] }
    }

    // MARK: Shared helpers

    /// REPLAYGAIN_TRACK_GAIN = "-6.48 dB" and friends (any case; ID3 TXXX and MP4 freeform too).
    static func applyReplayGain(_ key: String, _ value: String, to info: inout TagInfo) {
        let num = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(num), v.isFinite else { return }
        switch key.uppercased() {
        case "REPLAYGAIN_TRACK_GAIN": info.rgTrackGain = v
        case "REPLAYGAIN_ALBUM_GAIN": info.rgAlbumGain = v
        case "REPLAYGAIN_TRACK_PEAK": info.rgTrackPeak = v
        case "REPLAYGAIN_ALBUM_PEAK": info.rgAlbumPeak = v
        default: break
        }
    }

    static func applyVorbisComment(_ key: String, _ value: String, to info: inout TagInfo, wantArtwork: Bool) {
        switch key.uppercased() {
        case "TITLE": if info.title.isEmpty { info.title = value }
        case "ARTIST": if info.artist.isEmpty { info.artist = value }
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": if info.albumArtist.isEmpty { info.albumArtist = value }
        case "ALBUM": if info.album.isEmpty { info.album = value }
        case "GENRE": if info.genre.isEmpty { info.genre = value }
        case "DATE", "YEAR", "ORIGINALDATE": if info.year == 0 { info.year = parseYear(value) }
        case "TRACKNUMBER":
            info.track = parseNumber(value)
            if info.trackTotal == 0 { info.trackTotal = parseTotal(value) }
        case "DISCNUMBER":
            info.disc = parseNumber(value)
            if info.discTotal == 0 { info.discTotal = parseTotal(value) }
        case "TRACKTOTAL", "TOTALTRACKS": info.trackTotal = parseNumber(value)
        case "DISCTOTAL", "TOTALDISCS": info.discTotal = parseNumber(value)
        case "COMPOSER": if info.composer.isEmpty { info.composer = value }
        case "GROUPING", "CONTENTGROUP": if info.grouping.isEmpty { info.grouping = value }
        case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS":
            if info.lyrics == nil, value.utf8.count <= Lyrics.maximumSize { info.lyrics = value }
        case "SYNCEDLYRICS", "SYNCED LYRICS":
            if value.utf8.count <= Lyrics.maximumSize { info.timedLyrics = Lyrics.parse(value).timed }
        case "COMMENT", "DESCRIPTION": if info.comment.isEmpty { info.comment = value }
        case "BPM": info.bpm = parseNumber(value)
        case "COMPILATION": info.compilation = value == "1" || value.lowercased() == "true"
        case "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_PEAK":
            applyReplayGain(key, value, to: &info)
        case "METADATA_BLOCK_PICTURE":
            if wantArtwork, info.artwork == nil,
               let raw = Data(base64Encoded: value, options: .ignoreUnknownCharacters) {
                info.artwork = FLACReader.parsePicture([UInt8](raw))
            }
        default: break
        }
    }

    /// Parses the Vorbis-comment structure shared by FLAC, Ogg Vorbis and Opus.
    static func parseVorbisComments(_ b: [UInt8], at start: Int, into info: inout TagInfo, wantArtwork: Bool) {
        var o = start
        let vendorLen = b.u32le(o); o += 4 + vendorLen
        guard o + 4 <= b.count else { return }
        let count = b.u32le(o); o += 4
        for _ in 0..<min(count, 10_000) {
            guard o + 4 <= b.count else { return }
            let len = b.u32le(o); o += 4
            guard len >= 0, o + len <= b.count else { return }
            let entry = b.utf8(o, len)
            o += len
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            let value = String(entry[entry.index(after: eq)...])
            applyVorbisComment(key, value, to: &info, wantArtwork: wantArtwork)
        }
    }

    static func parseYear(_ s: String) -> Int {
        let digits = s.prefix(while: { $0.isNumber || $0 == " " }).filter(\.isNumber)
        guard digits.count >= 4 else { return 0 }
        return Int(digits.prefix(4)) ?? 0
    }

    /// "3/12" → 12
    static func parseTotal(_ s: String) -> Int {
        guard let slash = s.firstIndex(of: "/") else { return 0 }
        return parseNumber(String(s[s.index(after: slash)...]))
    }

    /// "3", "3/12", "03 of 12" → 3
    static func parseNumber(_ s: String) -> Int {
        Int(s.trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber)) ?? 0
    }

    static let id3Genres: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic", "Bluegrass",
        "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic",
        "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove",
        "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore",
        "Terror", "Indie", "BritPop", "Negerpunk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover",
        "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "J-Pop", "Synthpop"
    ]

    static func genreName(index: Int) -> String {
        index >= 0 && index < id3Genres.count ? id3Genres[index] : ""
    }
}

// MARK: - Low-level reading

final class FileReader {
    let handle: FileHandle
    let size: Int64

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = h
        size = (try? h.seekToEnd()).map { Int64($0) } ?? 0
    }

    deinit { try? handle.close() }

    /// Reads up to `count` bytes at `offset`; returns fewer near EOF, empty on error.
    func read(at offset: Int64, count: Int) -> [UInt8] {
        guard offset >= 0, offset < size, count > 0 else { return [] }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let n = Int(min(Int64(count), size - offset))
            guard let data = try handle.read(upToCount: n) else { return [] }
            return [UInt8](data)
        } catch {
            return []
        }
    }
}

extension Array where Element == UInt8 {
    func u8(_ o: Int) -> Int { o >= 0 && o < count ? Int(self[o]) : 0 }

    func u16be(_ o: Int) -> Int {
        guard o >= 0, o + 2 <= count else { return 0 }
        return Int(self[o]) << 8 | Int(self[o + 1])
    }

    func u16le(_ o: Int) -> Int {
        guard o >= 0, o + 2 <= count else { return 0 }
        return Int(self[o + 1]) << 8 | Int(self[o])
    }

    func u24be(_ o: Int) -> Int {
        guard o >= 0, o + 3 <= count else { return 0 }
        return Int(self[o]) << 16 | Int(self[o + 1]) << 8 | Int(self[o + 2])
    }

    func u32be(_ o: Int) -> Int {
        guard o >= 0, o + 4 <= count else { return 0 }
        return Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }

    func u32le(_ o: Int) -> Int {
        guard o >= 0, o + 4 <= count else { return 0 }
        return Int(self[o + 3]) << 24 | Int(self[o + 2]) << 16 | Int(self[o + 1]) << 8 | Int(self[o])
    }

    func u64be(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(self[o + i]) }
        return v
    }

    func u64le(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(self[o + i]) }
        return v
    }

    func syncsafe(_ o: Int) -> Int {
        guard o >= 0, o + 4 <= count else { return 0 }
        return Int(self[o] & 0x7F) << 21 | Int(self[o + 1] & 0x7F) << 14 | Int(self[o + 2] & 0x7F) << 7 | Int(self[o + 3] & 0x7F)
    }

    func bytes(_ o: Int, _ n: Int) -> [UInt8] {
        guard o >= 0, n > 0, o < count else { return [] }
        return Array(self[o..<Swift.min(o + n, count)])
    }

    func latin1(_ o: Int, _ n: Int) -> String {
        String(decoding: bytes(o, n).map { UInt16($0) }, as: UTF16.self)
    }

    func utf8(_ o: Int, _ n: Int) -> String {
        String(decoding: bytes(o, n), as: UTF8.self)
    }

    func matches(_ s: String, at o: Int) -> Bool {
        let b = Array(s.utf8)
        guard o >= 0, o + b.count <= count else { return false }
        for i in 0..<b.count where self[o + i] != b[i] { return false }
        return true
    }

    func find(_ s: String, from start: Int = 0) -> Int? {
        let b = Array(s.utf8)
        guard !b.isEmpty, count >= b.count else { return nil }
        var i = Swift.max(0, start)
        while i <= count - b.count {
            if self[i] == b[0] && matches(s, at: i) { return i }
            i += 1
        }
        return nil
    }

    func findLast(_ s: String) -> Int? {
        let b = Array(s.utf8)
        guard !b.isEmpty, count >= b.count else { return nil }
        var i = count - b.count
        while i >= 0 {
            if self[i] == b[0] && matches(s, at: i) { return i }
            i -= 1
        }
        return nil
    }
}
