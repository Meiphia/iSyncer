import SwiftUI
import Combine

enum SourceSelection: Hashable {
    case library
    case artists
    case partyShuffle
    case smart(String)        // Top 25 Most Played, Recently Played, Recently Added, My Top Rated
    case playlist(UUID)
    case device(UUID)
    case videos
    case podcasts
    case audiobooks
    case health
    case smartList(UUID)

    var isSmartPlaylist: Bool {
        switch self {
        case .smart, .smartList: return true
        default: return false
        }
    }
}

/// What the song list shows: source + search + column browser + sort, computed once per change
/// (not on every redraw) so a 35k-song library stays responsive.
@MainActor
final class BrowserModel: ObservableObject {
    @Published var source: SourceSelection = .library {
        didSet {
            guard source != oldValue else { return }
            genreSel = []; artistSel = []; albumSel = []
            if source == .health { LibraryHealth.shared.analyzeIfNeeded() }
            sortKey = nil
            selection = []
            recompute()
        }
    }
    @Published var showUnplayedPodcasts = false {
        didSet { if source == .podcasts { recompute() } }
    }
    @Published var search = ""
    /// nil = the source's natural order (library: artist/album/track; playlists: their order).
    @Published var sortKey: String? = nil { didSet { if sortKey != oldValue { recompute() } } }
    @Published var sortAscending = true { didSet { if sortAscending != oldValue { recompute() } } }
    @Published var showColumnBrowser = UserDefaults.standard.object(forKey: "columnBrowser") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showColumnBrowser, forKey: "columnBrowser")
            if !showColumnBrowser { genreSel = []; artistSel = []; albumSel = [] }
            recompute()
        }
    }
    @Published var showArtwork = UserDefaults.standard.object(forKey: "showArtwork") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showArtwork, forKey: "showArtwork") }
    }
    /// The column browser's Album pane shows covers instead of a list.
    @Published var showAlbumArtwork = UserDefaults.standard.object(forKey: "showAlbumArtwork") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showAlbumArtwork, forKey: "showAlbumArtwork")
            if showAlbumArtwork && !showColumnBrowser { showColumnBrowser = true } else { recompute() }
        }
    }
    @Published var showVisualizer = false
    @Published var showCoverFlow = false
    @Published var showExpandedPlayer = false
    /// Column browser selections; empty = All. Cmd/Shift-click picks several.
    @Published var genreSel = Set<String>() { didSet { if genreSel != oldValue { artistSel = []; albumSel = []; recompute() } } }
    @Published var artistSel = Set<String>() { didSet { if artistSel != oldValue { albumSel = []; recompute() } } }
    @Published var albumSel = Set<String>() { didSet { if albumSel != oldValue { recompute() } } }
    /// Single-item views of the selections (nil when All or several are selected).
    var genre: String? {
        get { genreSel.count == 1 ? genreSel.first : nil }
        set { genreSel = newValue.map { [$0] } ?? [] }
    }
    var artist: String? {
        get { artistSel.count == 1 ? artistSel.first : nil }
        set { artistSel = newValue.map { [$0] } ?? [] }
    }
    var album: String? {
        get { albumSel.count == 1 ? albumSel.first : nil }
        set { albumSel = newValue.map { [$0] } ?? [] }
    }
    /// Which Library Health list is showing.
    @Published var healthCheck: HealthCheck = .duplicates { didSet { if healthCheck != oldValue { recompute() } } }
    @Published var selection = Set<Track.ID>()
    /// Bumped to ask the song list to scroll to the playing song.
    @Published var revealRequest = 0

    @Published private(set) var visible: [Track] = []
    @Published private(set) var genres: [String] = []
    @Published private(set) var artists: [String] = []
    @Published private(set) var albums: [String] = []
    /// Covers for the Album pane's artwork view, in the same order as `albums`.
    @Published private(set) var albumSummaries: [AlbumSummary] = []
    @Published private(set) var summary = ""

    private let library = LibraryStore.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        BrowserModelLink.browser = self
        library.$tracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.source == .health { LibraryHealth.shared.analyze() }
                self.recompute()
            }
            .store(in: &cancellables)
        library.$playlists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, case .playlist = self.source else { return }
                self.recompute()
            }
            .store(in: &cancellables)
        library.$unchecked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.source == .partyShuffle { self.recompute() }
                if self.source.isSmartPlaylist { self.recompute() }
            }
            .store(in: &cancellables)
        library.$smartLists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.source.isSmartPlaylist else { return }
                self.recompute()
            }
            .store(in: &cancellables)
        LibraryHealth.shared.$results
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.source == .health else { return }
                self.recompute()
            }
            .store(in: &cancellables)
        PartyShuffle.shared.$list
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.source == .partyShuffle else { return }
                self.recompute()
            }
            .store(in: &cancellables)
        $search
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    /// An editable, user-made playlist (drag to reorder, delete to remove).
    var isPlaylist: Bool {
        if case .playlist = source { return true }
        return false
    }

    /// Any list with its own order, where the column browser doesn't apply.
    var isListSource: Bool {
        switch source {
        case .playlist, .smart, .partyShuffle, .health, .smartList: return true
        default: return false
        }
    }

    var currentPlaylist: Playlist? {
        if case .playlist(let id) = source { return library.playlist(id) }
        return nil
    }

    /// Reordering by drag only makes sense when what you see is the playlist's real order.
    var canReorder: Bool {
        isPlaylist && sortKey == nil && search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func recompute() {
        var base: [Track]
        switch source {
        case .library, .artists: base = library.tracks.filter(\.isMusic)
        case .podcasts: base = library.tracks.filter { $0.podcastShow != nil && (!showUnplayedPodcasts || $0.finishedListening != true) }
        case .audiobooks: base = library.tracks.filter { $0.audiobookTitle != nil }
        case .playlist(let id): base = library.playlist(id).map { library.tracks(in: $0) } ?? []
        case .smart(let name): base = library.smartPlaylist(named: name).map { library.tracks(in: $0) } ?? []
        case .partyShuffle: base = PartyShuffle.shared.list.compactMap { library.track($0) }
        case .smartList(let id): base = library.tracks(inSmart: id)
        case .health: base = LibraryHealth.shared.ids(for: healthCheck).compactMap { library.track($0) }
        case .device, .videos: base = []
        }

        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let words = q.lowercased().split(separator: " ").map(String.init)
            let isPodcasts = source == .podcasts
            base = base.filter { t in
                let show = isPodcasts ? t.podcastShow ?? "" : ""
                let hay = [t.title, t.artist, t.albumArtist, t.album, t.genre, t.composerHint, show]
                    .joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
        }

        // Podcasts group by show. The other browsers cascade through genre, artist and album.
        if showColumnBrowser && source == .podcasts {
            let shows = Dictionary(grouping: base) { $0.podcastShow ?? "" }
            genres = []
            artists = []
            albums = Self.uniqueSorted(Array(shows.keys))
            albumSummaries = albums.compactMap { name in
                guard let episodes = shows[name], let first = episodes.first else { return nil }
                return AlbumSummary(name: name, year: episodes.map(\.year).max() ?? 0,
                                    count: episodes.count, first: first)
            }
            if !albumSel.isEmpty {
                base = base.filter { albumSel.contains($0.podcastShow ?? "") }
            }
        } else if showColumnBrowser && !isListSource {
            genres = Self.uniqueSorted(base.map(\.genre))
            let byGenre = genreSel.isEmpty ? base : base.filter { genreSel.contains($0.genre) }
            artists = Self.uniqueSorted(byGenre.map(\.displayAlbumArtist))
            let byArtist = artistSel.isEmpty ? byGenre : byGenre.filter { artistSel.contains($0.displayAlbumArtist) }
            albums = Self.uniqueSorted(byArtist.map(\.album))
            if showAlbumArtwork {
                var groups: [String: [Track]] = [:]
                for t in byArtist where !t.album.isEmpty { groups[t.album, default: []].append(t) }
                albumSummaries = albums.compactMap { name in
                    guard let ts = groups[name], !ts.isEmpty else { return nil }
                    let first = ts.min { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) } ?? ts[0]
                    return AlbumSummary(name: name, year: ts.map(\.year).max() ?? 0, count: ts.count, first: first)
                }
            } else {
                albumSummaries = []
            }
            base = albumSel.isEmpty ? byArtist : byArtist.filter { albumSel.contains($0.album) }
        }

        if let sortKey {
            base = TrackSort.sorted(base, key: sortKey, ascending: sortAscending)
        }
        visible = base

        let seconds = base.reduce(0.0) { $0 + $1.duration }
        let bytes = base.reduce(Int64(0)) { $0 + $1.size }
        summary = base.isEmpty ? "" : Format.summary(count: base.count, seconds: seconds, bytes: bytes,
                                                       item: source == .podcasts ? "episode" : "song")
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// IDs in display order, for playing "from here".
    var visibleIDs: [String] { visible.map(\.id) }

    /// Songs (in the current source, search and genre/artist filter) for column browser items.
    func trackIDs(column: String, values: Set<String>) -> [String] {
        let pool: [Track]
        switch source {
        case .library: pool = library.tracks.filter(\.isMusic)
        default: pool = visible
        }
        return pool.filter { t in
            switch column {
            case "Genre": return values.contains(t.genre)
            case "Artist": return values.contains(t.displayAlbumArtist)
            default: return values.contains(t.album) && (artistSel.isEmpty || artistSel.contains(t.displayAlbumArtist))
            }
        }.map(\.id)
    }

    // MARK: ➜ links

    func showArtist(of t: Track) {
        source = .library
        search = ""
        showColumnBrowser = true
        genre = nil
        artist = t.displayAlbumArtist
        selection = [t.id]
    }

    func showAlbum(of t: Track) {
        source = t.podcastShow != nil ? .podcasts : t.audiobookTitle != nil ? .audiobooks : .library
        if t.podcastShow != nil { showUnplayedPodcasts = false }
        search = ""
        showColumnBrowser = true
        genre = nil
        artist = t.displayAlbumArtist
        album = t.podcastShow ?? t.album
        selection = [t.id]
    }
}

extension Track {
    /// Search also matches the file name, which often carries extra info.
    var composerHint: String { (id as NSString).lastPathComponent }
}

/// Column sorting for the song list. Sort keys are folded once per sort (not per comparison),
/// and ties fall back to album artist / album / disc / track like iTunes.
enum TrackSort {
    static let numericKeys: Set<String> = ["duration", "trackNumber", "year", "playCount", "rating",
                                           "lastPlayed", "dateAdded", "bitrate", "size", "sampleRate"]

    static func sorted(_ tracks: [Track], key: String, ascending: Bool) -> [Track] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

        if numericKeys.contains(key) {
            let values: [Double] = tracks.map { t in
                switch key {
                case "duration": return t.duration
                case "trackNumber": return Double(t.discNumber * 1000 + t.trackNumber)
                case "year": return Double(t.year)
                case "playCount": return Double(t.playCount)
                case "rating": return Double(t.rating)
                case "lastPlayed": return t.lastPlayed
                case "dateAdded": return t.dateAdded
                case "bitrate": return Double(t.bitrate)
                case "sampleRate": return Double(t.sampleRate)
                default: return Double(t.size)
                }
            }
            let order = tracks.indices.sorted { a, b in
                if values[a] != values[b] { return ascending ? values[a] < values[b] : values[a] > values[b] }
                return a < b
            }
            return order.map { tracks[$0] }
        }

        // String keys, with sensible secondary keys.
        let keys: [[String]] = tracks.map { t in
            let pos = String(format: "%04d%04d", t.discNumber, t.trackNumber)
            switch key {
            case "artist": return [fold(t.artist), fold(t.album), pos]
            case "albumArtist": return [fold(t.displayAlbumArtist), fold(t.album), pos]
            case "album": return [fold(t.album), pos]
            case "podcastShow": return [fold(t.podcastShow ?? ""), pos]
            case "genre": return [fold(t.genre), fold(t.displayAlbumArtist), fold(t.album), pos]
            case "codec": return [fold(t.kind), fold(t.title)]
            default: return [fold(t.title), fold(t.artist)]
            }
        }
        let order = tracks.indices.sorted { a, b in
            let ka = keys[a], kb = keys[b]
            // Empty values sort last, like iTunes.
            if ka[0].isEmpty != kb[0].isEmpty { return kb[0].isEmpty }
            if ka != kb { return ascending ? ka.lexicographicallyPrecedes(kb) : kb.lexicographicallyPrecedes(ka) }
            return a < b
        }
        return order.map { tracks[$0] }
    }
}
