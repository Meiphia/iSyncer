import Foundation

enum HealthCheck: String, CaseIterable, Identifiable, Sendable {
    case duplicates, names, mixedAlbums, missingInfo, noArtwork, unreadable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duplicates: return "Duplicates"
        case .names: return "Similar Names"
        case .mixedAlbums: return "Mixed Albums"
        case .missingInfo: return "Missing Info"
        case .noArtwork: return "No Artwork"
        case .unreadable: return "Unreadable"
        }
    }

    var explanation: String {
        switch self {
        case .duplicates:
            return "The same artist and title more than once, with about the same length. Grouped together; sort by Name to compare."
        case .names:
            return "Genres or artists spelled differently (case, spaces, hyphens, accents, “The”). Cmd-click them in the column browser, or select songs here, then Get Info to make them match."
        case .mixedAlbums:
            return "Songs in one album folder that disagree on album artist, year or genre, so the album splits up on the player."
        case .missingInfo:
            return "No title, artist, album, genre or track number."
        case .noArtwork:
            return "Albums with no embedded cover and no cover image in the folder. Add one with Get Info → Artwork."
        case .unreadable:
            return "Files whose length or format couldn't be read. They may be damaged or not really audio."
        }
    }
}

/// Finds library problems for the Library Health source. Everything but the artwork check comes
/// from the library's own data, so it's quick; the artwork check reads one file per album.
@MainActor
final class LibraryHealth: ObservableObject {
    static let shared = LibraryHealth()

    @Published private(set) var results: [HealthCheck: [String]] = [:]
    @Published private(set) var analyzing = false
    @Published private(set) var artworkProgress: Double?
    @Published private(set) var artworkChecked = false
    private var analyzedCount = -1
    private var artworkTask: Task<Void, Never>?

    func ids(for check: HealthCheck) -> [String] { results[check] ?? [] }
    func count(_ check: HealthCheck) -> Int? {
        if check == .noArtwork && !artworkChecked { return nil }
        return results[check]?.count
    }

    func analyzeIfNeeded() {
        if analyzedCount != LibraryStore.shared.tracks.count { analyze() }
    }

    func analyze() {
        let tracks = LibraryStore.shared.tracks
        analyzedCount = tracks.count
        analyzing = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Self.quickChecks(tracks) }.value
            var merged = r
            merged[.noArtwork] = results[.noArtwork] ?? []
            results = merged
            analyzing = false
        }
    }

    func checkArtwork() {
        artworkTask?.cancel()
        guard let root = LibraryStore.shared.libraryRoot else { return }
        let tracks = LibraryStore.shared.tracks
        artworkProgress = 0
        artworkTask = Task {
            // One representative song per album folder.
            var albums: [String: [String]] = [:]
            for t in tracks {
                let key = (t.id as NSString).deletingLastPathComponent + "|" + t.album
                albums[key, default: []].append(t.id)
            }
            let groups = Array(albums.values)
            var missing: [String] = []
            let chunk = 40
            var i = 0
            while i < groups.count {
                if Task.isCancelled { return }
                let slice = Array(groups[i..<min(i + chunk, groups.count)])
                let found: [[String]] = await Task.detached(priority: .utility) {
                    slice.filter { ids in
                        let url = root.appendingLibraryPath(ids[0])
                        if ArtworkLoader.folderImage(in: url.deletingLastPathComponent()) != nil { return false }
                        return TagReader.read(url: url, wantArtwork: true)?.artwork == nil
                    }
                }.value
                missing += found.flatMap { $0 }
                i += chunk
                artworkProgress = Double(i) / Double(max(groups.count, 1))
            }
            let order = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
            results[.noArtwork] = missing.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
            artworkChecked = true
            artworkProgress = nil
        }
    }

    // MARK: Checks

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// For "Similar Names": ignores case, accents, spaces, punctuation, "&"/"and" and a leading "The".
    nonisolated static func nameKey(_ s: String) -> String {
        var f = fold(s)
        if f.hasPrefix("the ") { f.removeFirst(4) }
        f = f.replacingOccurrences(of: "&", with: "and")
        return String(f.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    nonisolated static func quickChecks(_ tracks: [Track]) -> [HealthCheck: [String]] {
        var out: [HealthCheck: [String]] = [:]

        // Duplicates: same artist + title, lengths within 3 seconds.
        var byKey: [String: [Track]] = [:]
        for t in tracks where !t.title.isEmpty {
            byKey[fold(t.artist) + "\u{1}" + fold(t.title), default: []].append(t)
        }
        var dupes: [String] = []
        for key in byKey.keys.sorted() {
            let group = byKey[key]!.sorted { $0.duration < $1.duration }
            guard group.count > 1 else { continue }
            var cluster: [Track] = [group[0]]
            func flush() { if cluster.count > 1 { dupes += cluster.map(\.id) } }
            for t in group.dropFirst() {
                if abs(t.duration - cluster.last!.duration) <= 3 { cluster.append(t) } else { flush(); cluster = [t] }
            }
            flush()
        }
        out[.duplicates] = dupes

        // Similar names: genres, artists and album artists with more than one spelling.
        var names: [String] = []
        var seen = Set<String>()
        for field in [\Track.genre, \Track.artist, \Track.albumArtist] {
            var spellings: [String: Set<String>] = [:]
            for t in tracks {
                let v = t[keyPath: field]
                guard !v.isEmpty else { continue }
                spellings[nameKey(v), default: []].insert(v)
            }
            let bad = Set(spellings.values.filter { $0.count > 1 }.flatMap { $0 })
            guard !bad.isEmpty else { continue }
            for t in tracks where bad.contains(t[keyPath: field]) && seen.insert(t.id).inserted {
                names.append(t.id)
            }
        }
        out[.names] = names

        // Mixed albums: one folder + album name, different album artist / year / genre.
        var albums: [String: [Track]] = [:]
        for t in tracks where !t.album.isEmpty {
            albums[(t.id as NSString).deletingLastPathComponent + "\u{1}" + t.album, default: []].append(t)
        }
        var mixed: [String] = []
        for key in albums.keys.sorted() {
            let g = albums[key]!
            guard g.count > 1 else { continue }
            let artists = Set(g.map(\.displayAlbumArtist))
            let years = Set(g.map(\.year).filter { $0 > 0 })
            let genres = Set(g.map(\.genre))
            if artists.count > 1 || years.count > 1 || genres.count > 1 { mixed += g.map(\.id) }
        }
        out[.mixedAlbums] = mixed

        out[.missingInfo] = tracks.filter {
            $0.title.isEmpty || $0.artist.isEmpty || $0.album.isEmpty || $0.genre.isEmpty || $0.trackNumber == 0
        }.map(\.id)

        out[.unreadable] = tracks.filter { $0.duration <= 0 || $0.codec.isEmpty }.map(\.id)
        return out
    }
}
