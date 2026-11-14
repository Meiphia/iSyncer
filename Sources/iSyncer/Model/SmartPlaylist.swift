import ClassicSync
import Foundation

/// An iTunes-style smart playlist: rules, an optional limit, live updating.
struct SmartPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "untitled smart playlist"
    var matchAll = true
    var rules: [SmartRule] = [SmartRule()]
    var limitEnabled = false
    var limitCount: Double = 25
    var limitUnit: LimitUnit = .songs
    var selectedBy: SelectedBy = .random
    var onlyChecked = false
    /// Keeps a random selection stable until the playlist is edited.
    var seed: UInt64 = UInt64.random(in: 0...UInt64.max)

    enum LimitUnit: String, Codable, CaseIterable, Identifiable, Sendable {
        case songs, minutes, hours, MB, GB
        var id: String { rawValue }
        var label: String { rawValue == "songs" ? "songs" : rawValue }
    }

    enum SelectedBy: String, Codable, CaseIterable, Identifiable, Sendable {
        case random, album, artist, genre, name, libraryOrder
        case highestRating, lowestRating
        case mostRecentlyPlayed, leastRecentlyPlayed
        case mostOftenPlayed, leastOftenPlayed
        case mostRecentlyAdded, leastRecentlyAdded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .random: return "random"
            case .libraryOrder: return "library order"
            case .album: return "album"
            case .artist: return "artist"
            case .genre: return "genre"
            case .name: return "name"
            case .highestRating: return "highest rating"
            case .lowestRating: return "lowest rating"
            case .mostRecentlyPlayed: return "most recently played"
            case .leastRecentlyPlayed: return "least recently played"
            case .mostOftenPlayed: return "most often played"
            case .leastOftenPlayed: return "least often played"
            case .mostRecentlyAdded: return "most recently added"
            case .leastRecentlyAdded: return "least recently added"
            }
        }
    }

    /// The matching song IDs, in the order the limit selected them (library order otherwise).
    func evaluate(_ tracks: [Track], unchecked: Set<String>, now: Date = Date()) -> [String] {
        let active = rules.filter { $0.isComplete }
        var list = tracks.filter { t in
            if onlyChecked && unchecked.contains(t.id) { return false }
            if active.isEmpty { return true }
            return matchAll ? active.allSatisfy { $0.matches(t, now: now) } : active.contains { $0.matches(t, now: now) }
        }
        guard limitEnabled, limitCount > 0 else { return list.map(\.id) }
        list = sortForLimit(list)
        var out: [String] = []
        var used = 0.0
        for t in list {
            let cost: Double
            switch limitUnit {
            case .songs: cost = 1
            case .minutes: cost = t.duration / 60
            case .hours: cost = t.duration / 3600
            case .MB: cost = Double(t.size) / 1_000_000
            case .GB: cost = Double(t.size) / 1_000_000_000
            }
            if used + cost > limitCount && !out.isEmpty { if limitUnit == .songs { break } else { continue } }
            used += cost
            out.append(t.id)
            if used >= limitCount { break }
        }
        return out
    }

    private func sortForLimit(_ list: [Track]) -> [Track] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        switch selectedBy {
        case .libraryOrder: return list
        case .random:
            return list.sorted { Self.mix($0.id, seed) < Self.mix($1.id, seed) }
        case .album: return list.sorted { (fold($0.album), $0.discNumber, $0.trackNumber) < (fold($1.album), $1.discNumber, $1.trackNumber) }
        case .artist: return list.sorted { (fold($0.artist), fold($0.album), $0.trackNumber) < (fold($1.artist), fold($1.album), $1.trackNumber) }
        case .genre: return list.sorted { (fold($0.genre), fold($0.artist)) < (fold($1.genre), fold($1.artist)) }
        case .name: return list.sorted { fold($0.title) < fold($1.title) }
        case .highestRating: return list.sorted { $0.rating > $1.rating }
        case .lowestRating: return list.sorted { $0.rating < $1.rating }
        case .mostRecentlyPlayed: return list.sorted { $0.lastPlayed > $1.lastPlayed }
        case .leastRecentlyPlayed: return list.sorted { $0.lastPlayed < $1.lastPlayed }
        case .mostOftenPlayed: return list.sorted { $0.playCount > $1.playCount }
        case .leastOftenPlayed: return list.sorted { $0.playCount < $1.playCount }
        case .mostRecentlyAdded: return list.sorted { $0.dateAdded > $1.dateAdded }
        case .leastRecentlyAdded: return list.sorted { $0.dateAdded < $1.dateAdded }
        }
    }

    /// Stable pseudo-random order: FNV-1a of the id, mixed with the seed.
    private static func mix(_ id: String, _ seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 ^ seed
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33
        return h
    }
}

struct SmartRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var field: Field = .artist
    var op: Op = .contains
    var text = ""
    var number: Double = 0
    var number2: Double = 0
    var unit: DateUnit = .days

    init() {}

    init(previousRule rule: PlaylistRule) {
        switch rule.field {
        case .title: field = .title
        case .artist: field = .artist
        case .albumArtist: field = .albumArtist
        case .album: field = .album
        case .genre: field = .genre
        case .year: field = .yearText
        }
        switch rule.operation {
        case .contains: op = .contains
        case .excludes: op = .notContains
        case .equals: op = .isEqual
        case .starts: op = .beginsWith
        case .ends: op = .endsWith
        }
        text = rule.value
    }

    enum Kind { case text, number, date, rating }

    enum Field: String, Codable, CaseIterable, Identifiable, Sendable {
        case title, artist, albumArtist, album, genre, kind, yearText
        case year, rating, playCount, duration, bitrate
        case lastPlayed, dateAdded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Name"
            case .artist: return "Artist"
            case .albumArtist: return "Album Artist"
            case .album: return "Album"
            case .genre: return "Genre"
            case .kind: return "Kind"
            case .year: return "Year"
            case .yearText: return "Year (text)"
            case .rating: return "My Rating"
            case .playCount: return "Plays"
            case .duration: return "Time"
            case .bitrate: return "Bit Rate"
            case .lastPlayed: return "Last Played"
            case .dateAdded: return "Date Added"
            }
        }
        var kind: Kind {
            switch self {
            case .title, .artist, .albumArtist, .album, .genre, .kind, .yearText: return .text
            case .year, .playCount, .duration, .bitrate: return .number
            case .rating: return .rating
            case .lastPlayed, .dateAdded: return .date
            }
        }
        /// Shown after number fields.
        var suffix: String {
            switch self {
            case .duration: return "minutes"
            case .bitrate: return "kbps"
            default: return ""
            }
        }
    }

    enum Op: String, Codable, CaseIterable, Identifiable, Sendable {
        case contains, notContains, isEqual, isNot, beginsWith, endsWith
        case greater, less, inRange
        case inLast, notInLast, before, after
        var id: String { rawValue }
        var label: String {
            switch self {
            case .contains: return "contains"
            case .notContains: return "does not contain"
            case .isEqual: return "is"
            case .isNot: return "is not"
            case .beginsWith: return "starts with"
            case .endsWith: return "ends with"
            case .greater: return "is greater than"
            case .less: return "is less than"
            case .inRange: return "is in the range"
            case .inLast: return "is in the last"
            case .notInLast: return "is not in the last"
            case .before: return "is before"
            case .after: return "is after"
            }
        }
        static func options(for kind: Kind) -> [Op] {
            switch kind {
            case .text: return [.contains, .notContains, .isEqual, .isNot, .beginsWith, .endsWith]
            case .number: return [.isEqual, .isNot, .greater, .less, .inRange]
            case .rating: return [.isEqual, .isNot, .greater, .less, .inRange]
            case .date: return [.inLast, .notInLast, .before, .after]
            }
        }
    }

    enum DateUnit: String, Codable, CaseIterable, Identifiable, Sendable {
        case days, weeks, months
        var id: String { rawValue }
        var seconds: Double {
            switch self {
            case .days: return 86_400
            case .weeks: return 7 * 86_400
            case .months: return 30.44 * 86_400
            }
        }
    }

    var isComplete: Bool {
        field.kind == .text ? (op == .contains || op == .notContains ? !text.isEmpty : true) : true
    }

    func matches(_ t: Track, now: Date) -> Bool {
        switch field.kind {
        case .text:
            let v: String
            switch field {
            case .title: v = t.title
            case .artist: v = t.artist
            case .albumArtist: v = t.displayAlbumArtist
            case .album: v = t.album
            case .genre: v = t.genre
            case .yearText: v = String(t.year)
            default: v = t.kind
            }
            let a = v.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let b = text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            switch op {
            case .contains: return a.contains(b)
            case .notContains: return !a.contains(b)
            case .isEqual: return a == b
            case .isNot: return a != b
            case .beginsWith: return a.hasPrefix(b)
            case .endsWith: return a.hasSuffix(b)
            default: return false
            }
        case .number, .rating:
            let v: Double
            switch field {
            case .year: v = Double(t.year)
            case .playCount: v = Double(t.playCount)
            case .duration: v = t.duration / 60
            case .bitrate: v = Double(t.bitrate)
            default: v = Double(t.rating)
            }
            switch op {
            case .isEqual: return field == .duration ? abs(v - number) < 0.5 : v == number
            case .isNot: return field == .duration ? abs(v - number) >= 0.5 : v != number
            case .greater: return v > number
            case .less: return v < number
            case .inRange: return v >= min(number, number2) && v <= max(number, number2)
            default: return false
            }
        case .date:
            let v = field == .lastPlayed ? t.lastPlayed : t.dateAdded
            switch op {
            case .inLast: return v > 0 && v >= now.timeIntervalSince1970 - number * unit.seconds
            case .notInLast: return v == 0 || v < now.timeIntervalSince1970 - number * unit.seconds
            // `number` holds a date (seconds since 1970) for before/after.
            case .before: return v > 0 && v < number
            case .after: return v > number
            default: return false
            }
        }
    }
}
