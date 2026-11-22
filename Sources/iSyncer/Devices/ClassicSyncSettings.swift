import Foundation

struct ClassicSyncSettings: Codable, Equatable {
    var music = true
    var checkedOnly = true
    var selectedMusic = false
    var playlists: Set<String> = []
    var artists: Set<String> = []
    var albums: Set<String> = []
    var genres: Set<String> = []
    var movies = false
    var tvShows = false
    var podcasts = false
    var movieIDs: Set<String> = []
    var excludedVideos: [String: String]? = nil
    var showNames: Set<String> = []
    var tvRetention: [String: TVRetention]? = nil
    var tvOverrides: [String: [Int: TVSeasonSelection]]? = nil
    var podcastNames: Set<String> = []
    var podcastRetention: [String: PodcastRetention]? = nil
    var defaultPodcastLimit: Int? = nil
    var syncAudiobooks: Bool? = nil
    var selectedAudiobooks: Set<String>? = nil
    var fillRemainingSpace: Bool? = nil
    var reserveGB: Int? = nil
    var aacBitrate: Int? = nil
    var albumAACBitrates: [String: Int]? = nil
    var parallelEncodes: Int? = nil

    var musicAACBitrate: Int {
        get { ClassicEncoding.bitrates.contains(aacBitrate ?? 0) ? aacBitrate ?? 0 : 0 }
        set { aacBitrate = newValue == 0 ? nil : newValue }
    }

    func aacBitrate(for track: Track) -> Int {
        let override = albumAACBitrates?[track.classicEditionKey]
        return override.map { ClassicEncoding.bitrates.contains($0) ? $0 : 0 } ?? musicAACBitrate
    }

    mutating func setAlbumBitrate(_ bitrate: Int?, edition: String) {
        var overrides = albumAACBitrates ?? [:]
        overrides[edition] = bitrate
        albumAACBitrates = overrides.isEmpty ? nil : overrides
    }

    var encodingJobs: Int {
        get { max(1, min(8, parallelEncodes ?? ClassicEncoding.defaultJobs)) }
        set { parallelEncodes = newValue }
    }

    var audiobooks: Bool {
        get { syncAudiobooks ?? false }
        set { syncAudiobooks = newValue }
    }

    var audiobookNames: Set<String> {
        get { selectedAudiobooks ?? [] }
        set { selectedAudiobooks = newValue }
    }

    mutating func setPodcastRetention(_ value: PodcastRetention, for show: String) {
        var policies = podcastRetention ?? [:]
        policies[show] = value == PodcastRetention() ? nil : value
        podcastRetention = policies.isEmpty ? nil : policies
    }

    func podcastPolicy(for show: String) -> PodcastRetention {
        let policy = podcastRetention?[show] ?? PodcastRetention()
        guard policy.mode == .useDefault, let defaultPodcastLimit else { return policy }
        var effective = policy
        effective.explicitMode = .hardCap
        effective.limit = max(1, defaultPodcastLimit)
        return effective
    }

    func includesTVEpisode(_ episode: VideoItem) -> Bool {
        let season = tvOverrides?[episode.show]?[episode.season]
        return season?.episodes[episode.id] ?? season?.included ?? showNames.contains(episode.show)
    }

    mutating func selectTVShow(_ show: String, included: Bool) {
        if included { showNames.insert(show) } else { showNames.remove(show) }
        tvOverrides?.removeValue(forKey: show)
        if tvOverrides?.isEmpty == true { tvOverrides = nil }
    }

    mutating func selectTVSeason(_ season: Int, in show: String, included: Bool) {
        let override = included == showNames.contains(show) ? nil : TVSeasonSelection(included: included)
        setTVOverride(override, season: season, show: show)
    }

    mutating func selectTVEpisode(_ episode: VideoItem, included: Bool) {
        var season = tvOverrides?[episode.show]?[episode.season] ?? TVSeasonSelection()
        let inherited = season.included ?? showNames.contains(episode.show)
        season.episodes[episode.id] = included == inherited ? nil : included
        let override = season.included == nil && season.episodes.isEmpty ? nil : season
        setTVOverride(override, season: episode.season, show: episode.show)
    }

    mutating func moveEpisodes(_ moves: [PlannedEpisodeMove]) {
        moveEpisodes(moves.map { ($0.previous, $0.updated) })
    }

    mutating func moveEpisodes(_ moves: [(VideoItem, VideoItem)]) {
        let old = self
        for (previous, _) in moves {
            if var season = tvOverrides?[previous.show]?[previous.season] {
                season.episodes.removeValue(forKey: previous.id)
                setTVOverride(season.included == nil && season.episodes.isEmpty ? nil : season,
                              season: previous.season, show: previous.show)
            }
            tvRetention?[previous.show]?.pinned.remove(previous.id)
            excludedVideos?.removeValue(forKey: previous.classicTVKey)
        }
        for (previous, updated) in moves {
            if let choice = old.tvOverrides?[previous.show]?[previous.season]?.episodes[previous.id] {
                selectTVEpisode(updated, included: choice)
            }
            if old.tvRetention?[previous.show]?.pinned.contains(previous.id) == true {
                tvRetention?[updated.show]?.pinned.insert(updated.id)
            }
            if let exclusion = old.excludedVideos?[previous.classicTVKey] {
                excludedVideos?[updated.classicTVKey] = exclusion
            }
        }
    }

    private mutating func setTVOverride(_ override: TVSeasonSelection?, season: Int, show: String) {
        var shows = tvOverrides ?? [:]
        var seasons = shows[show] ?? [:]
        seasons[season] = override
        shows[show] = seasons.isEmpty ? nil : seasons
        tvOverrides = shows.isEmpty ? nil : shows
    }
}

struct PodcastRetention: Codable, Equatable {
    enum Mode: String, CaseIterable, Codable {
        case useDefault = "Use iPod Default"
        case all = "All Episodes"
        case checked = "All Checked Episodes"
        case hardCap = "Keep Only the Newest"
        case latest = "Latest Episodes + Pinned"
        case unplayed = "All Unplayed Episodes"
        case catchUp = "Catch Up"
    }

    var limit: Int? = nil
    var pinned: Set<String> = []
    var unplayedOnly: Bool? = nil
    var removeFinished: Bool? = nil
    var explicitMode: Mode? = nil

    var mode: Mode {
        if let explicitMode { return explicitMode }
        if unplayedOnly == true { return limit == nil ? .unplayed : .catchUp }
        return limit == nil ? .useDefault : .latest
    }

    mutating func select(_ mode: Mode) {
        let unplayed = mode == .unplayed || mode == .catchUp
        if unplayedOnly != true && unplayed { removeFinished = false }
        if !unplayed { removeFinished = nil }
        unplayedOnly = unplayed ? true : nil
        limit = [.hardCap, .latest, .catchUp].contains(mode) ? limit ?? 5 : nil
        explicitMode = mode == .useDefault ? nil : mode
    }

    // Older Unplayed rules also pruned finished episodes. Keep that behavior on upgrade.
    var removesFinished: Bool { removeFinished ?? (unplayedOnly == true) }
}

struct TVRetention: Codable, Equatable {
    var limit: Int? = nil
    var pinned: Set<String> = []
}

struct TVSeasonSelection: Codable, Equatable {
    var included: Bool? = nil
    var episodes: [String: Bool] = [:]
}

extension Track {
    var classicAlbumKey: String { "\(displayAlbumArtist)\u{1f}\(album)" }

    var podcastShow: String? {
        let components = id.split(separator: "/").dropLast()
        let folder = components.firstIndex { ["podcast", "podcasts"].contains($0.lowercased()) }
        guard folder != nil || genre.localizedCaseInsensitiveContains("podcast") else { return nil }
        if let folder, components.indices.contains(folder + 1) { return String(components[folder + 1]) }
        if !album.isEmpty { return album }
        return artist.isEmpty ? "Podcasts" : artist
    }
}

extension Track {
    var audiobookTitle: String? {
        guard fileExtension == "m4b" || id.split(separator: "/").dropLast().contains(where: {
            ["audiobook", "audiobooks"].contains($0.lowercased())
        }) || genre.localizedCaseInsensitiveContains("audiobook") else { return nil }
        return album.isEmpty ? title : album
    }

    var isMusic: Bool { podcastShow == nil && audiobookTitle == nil }
}
