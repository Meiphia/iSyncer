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
    var syncListeningProgress: Bool? = nil
    var syncAudiobooks: Bool? = nil
    var selectedAudiobooks: Set<String>? = nil
    var fillRemainingSpace: Bool? = nil
    var reserveGB: Int? = nil

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
        policies[show] = value.limit == nil && value.pinned.isEmpty && value.unplayedOnly != true ? nil : value
        podcastRetention = policies.isEmpty ? nil : policies
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

    private mutating func setTVOverride(_ override: TVSeasonSelection?, season: Int, show: String) {
        var shows = tvOverrides ?? [:]
        var seasons = shows[show] ?? [:]
        seasons[season] = override
        shows[show] = seasons.isEmpty ? nil : seasons
        tvOverrides = shows.isEmpty ? nil : shows
    }
}

struct PodcastRetention: Codable, Equatable {
    var limit: Int? = nil
    var pinned: Set<String> = []
    var unplayedOnly: Bool? = nil
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
