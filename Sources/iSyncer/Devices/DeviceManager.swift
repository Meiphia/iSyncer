import AppKit
import ClassicSync
import Combine

struct ClassicDevice: Identifiable {
    let id: UUID
    let value: Device
}

struct DeviceSyncReport: Codable {
    let device: String
    let date: Date
    let status: String
    let items: [SyncItem]
}

@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var connected: [ClassicDevice] = []
    @Published private(set) var busy = false {
        didSet {
            if !busy, !pendingPlayImports.isEmpty { Task { await importPendingPlays() } }
        }
    }
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?
    @Published private(set) var canStop = false
    @Published private(set) var plan: SyncPlan?
    @Published private(set) var skipped: [SyncItem] = []
    @Published private(set) var lastReports: [String: DeviceSyncReport] = [:]
    @Published private(set) var playImportResults: [String: String] = [:]
    @Published var automaticallyImportPlays = UserDefaults.standard.bool(forKey: "automaticallyImportClassicPlays") {
        didSet {
            UserDefaults.standard.set(automaticallyImportPlays, forKey: "automaticallyImportClassicPlays")
            pendingPlayImports = automaticallyImportPlays ? Set(connected.map(\.id)) : []
            Task { await importPendingPlays() }
        }
    }
    @Published private(set) var playbackConflict: PlaybackConflictRequest?
    @Published var message: String?
    @Published private(set) var settings: [String: ClassicSyncSettings] = {
        guard let data = UserDefaults.standard.data(forKey: "classicSyncSettings") else { return [:] }
        return (try? JSONDecoder().decode([String: ClassicSyncSettings].self, from: data)) ?? [:]
    }()

    func settings(for device: ClassicDevice) -> ClassicSyncSettings {
        settings[device.value.settingsID] ?? ClassicSyncSettings()
    }

    func setSettings(_ value: ClassicSyncSettings, for device: ClassicDevice) {
        settings[device.value.settingsID] = value
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "classicSyncSettings")
        }
        discardPreview()
    }

    func discardPreview() {
        playbackPreview = nil
        playbackConflict = nil
        plan = nil
        skipped = []
        previewPlayed = []
        previewWatched = []
        status = ""
    }
    @Published var useAlbumArtistForArtist = UserDefaults.standard.object(forKey: "useAlbumArtistForArtist") as? Bool
        ?? UserDefaults.standard.bool(forKey: "normalizeAlbumArtist") {
        didSet {
            UserDefaults.standard.set(useAlbumArtistForArtist, forKey: "useAlbumArtistForArtist")
            plan = nil
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var identities: [URL: UUID] = [:]
    private var refreshGeneration = 0
    private var libraryGeneration = 0
    private var plannedDevice: UUID?
    private var playbackPreview: PlaybackProgressSync?
    private var playbackBaselines: [String: [String: ClassicListeningState]] = {
        guard let data = UserDefaults.standard.data(forKey: "iPodPlaybackBaselines") else { return [:] }
        return (try? JSONDecoder().decode([String: [String: ClassicListeningState]].self, from: data)) ?? [:]
    }()
    private var previewPlayed = Set<URL>()
    private var previewWatched = Set<URL>()
    private var stop: SyncStop?
    private var pendingPlayImports: Set<UUID> = []

    func start() {
        guard observers.isEmpty else { return }
        if let data = try? Data(contentsOf: reportsURL),
           let reports = try? JSONDecoder().decode([String: DeviceSyncReport].self, from: data) {
            lastReports = reports
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        let library = LibraryStore.shared
        Publishers.MergeMany(
            VideoWatchHistory.shared.$watchedRevision.map { _ in () }.eraseToAnyPublisher(),
            library.$libraryRoot.map { _ in () }.eraseToAnyPublisher(),
            library.$tracks.map { _ in () }.eraseToAnyPublisher(),
            library.$unchecked.map { _ in () }.eraseToAnyPublisher(),
            library.$playlists.map { _ in () }.eraseToAnyPublisher(),
            library.$smartLists.map { _ in () }.eraseToAnyPublisher(),
            library.$isScanning.map { _ in () }.eraseToAnyPublisher(),
            library.$videos.map { _ in () }.eraseToAnyPublisher(),
            library.$videoMetadataRevision.map { _ in () }.eraseToAnyPublisher(),
            library.$uncheckedVideos.map { _ in () }.eraseToAnyPublisher()
        ).sink { [weak self] in
            self?.libraryGeneration += 1
            self?.plan = nil
            Task { await self?.importPendingPlays() }
        }.store(in: &subscriptions)
        Task { await refresh() }
    }

    func device(_ id: UUID) -> ClassicDevice? {
        connected.first { $0.id == id }
    }

    func preview(for id: UUID) -> SyncPlan? {
        plannedDevice == id ? plan : nil
    }

    private var reportsURL: URL { LibraryStore.supportFolder.appendingPathComponent("Sync Reports.json") }

    private func importPendingPlays() async {
        let library = LibraryStore.shared
        guard automaticallyImportPlays, !busy, !library.isScanning, library.libraryRoot != nil,
              let device = connected.first(where: { pendingPlayImports.contains($0.id) }) else { return }
        await importPlays(device, library: library, automatically: true)
    }

    func importPlays(_ device: ClassicDevice, library: LibraryStore, automatically: Bool = false) async {
        guard !busy, !library.isScanning, library.libraryRoot != nil else { return }
        pendingPlayImports.remove(device.id)
        busy = true
        if !automatically { status = "Reading iPod play counts…" }
        let id = device.value.settingsID
        playImportResults[id] = "Reading iPod play counts…"
        defer { busy = false }
        let root = library.libraryRoot
        do {
            let plays = try await Task.detached { try SyncEngine.readPlays(on: device.value) }.value
            guard self.device(device.id) != nil, root == library.libraryRoot, !library.isScanning else {
                playImportResults[id] = "Library or device changed. Import plays again."
                if !automatically { status = playImportResults[id] ?? "" }
                if automatically, automaticallyImportPlays, self.device(device.id) != nil { pendingPlayImports.insert(device.id) }
                return
            }
            let result = try library.importDevicePlays(plays, deviceID: id)
            let queued = LastFM.shared.addDevicePlays(result.scrobbles)
            let summary = result.count == 0 ? "No new matched iPod plays"
                : "\(result.count.formatted()) plays imported · \(queued.formatted()) queued for Last.fm"
            playImportResults[id] = summary
            if !automatically { status = summary }
        } catch {
            playImportResults[id] = "Could not import iPod plays. \(error.localizedDescription)"
            if !automatically {
                status = "Could not import iPod plays"
                message = error.localizedDescription
            }
        }
    }

    private func saveReport(for device: ClassicDevice, items: [SyncItem]) {
        lastReports[device.value.settingsID] = DeviceSyncReport(device: device.value.name, date: Date(), status: status, items: items)
        do {
            try JSONEncoder().encode(lastReports).write(to: reportsURL, options: .atomic)
        } catch {
            message = "Could not save the sync report: \(error.localizedDescription)"
        }
    }

    func readListening(_ device: ClassicDevice, library: LibraryStore) async -> [ListeningChange]? {
        guard !busy, !library.isScanning, let root = library.libraryRoot else { return nil }
        PlayerEngine.shared.saveCurrentListening()
        busy = true
        defer { busy = false }
        do {
            let plays = try await Task.detached { try SyncEngine.readPlays(on: device.value, includeVideo: true) }.value
            guard root == library.libraryRoot, self.device(device.id) != nil else { return nil }
            return library.listeningChanges(plays.filter { $0.kind == .music })
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func recover(_ items: [ClassicDeviceItem], from device: ClassicDevice, to folder: URL) async {
        guard !busy else { return }
        busy = true
        status = "Recovering media from iPod…"
        defer { busy = false }
        let result = await Task.detached {
            var count = 0
            var errors: [String] = []
            let fm = FileManager.default
            for item in items {
                let title = PathRules.sanitize([item.artist, item.title].filter { !$0.isEmpty }.joined(separator: " - "))
                let ext = PathRules.sanitize(item.fileExtension)
                var destination = folder.appendingPathComponent(title).appendingPathExtension(ext)
                var suffix = 2
                while fm.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent("\(title) \(suffix)").appendingPathExtension(ext)
                    suffix += 1
                }
                do {
                    try SyncEngine.recover(item, from: device.value, to: destination)
                    count += 1
                } catch { errors.append("\(item.title) · \(error.localizedDescription)") }
            }
            return (count, errors)
        }.value
        status = "\(result.0.formatted()) recovered"
        if !result.1.isEmpty { message = result.1.joined(separator: "\n") }
    }

    func refresh() async {
        refreshGeneration += 1
        let request = refreshGeneration
        let devices = await Task.detached(priority: .utility) { Device.connected() }.value
        guard request == refreshGeneration else { return }
        let previous = Set(connected.map(\.id))
        identities = identities.filter { mount, _ in devices.contains { $0.mount == mount } }
        connected = devices.map { value in
            let id = identities[value.mount] ?? UUID()
            identities[value.mount] = id
            return ClassicDevice(id: id, value: value)
        }
        let current = Set(connected.map(\.id))
        pendingPlayImports.formIntersection(current)
        if automaticallyImportPlays { pendingPlayImports.formUnion(current.subtracting(previous)) }
        if let plannedDevice, device(plannedDevice) == nil { discardPreview() }
        if let playbackConflict, device(playbackConflict.device) == nil { cancelPlaybackConflict() }
        await importPendingPlays()
    }

    func playbackConflict(for device: UUID) -> PlaybackConflictRequest? {
        playbackConflict?.device == device ? playbackConflict : nil
    }

    func cancelPlaybackConflict() {
        playbackConflict = nil
        status = ""
    }

    func resolvePlaybackConflict(_ request: PlaybackConflictRequest, choices: [String: Bool], library: LibraryStore) async {
        guard playbackConflict?.id == request.id, let device = device(request.device) else { return }
        let resolved = Dictionary(uniqueKeysWithValues: request.changes.compactMap { match in
            choices[match.id].map { preferIPod in
                (match.id, PlaybackProgressSync.Selection(mac: match.macState, iPod: match.iPodState, preferIPod: preferIPod))
            }
        })
        playbackConflict = nil
        await prepare(device, library: library, retry: request.retry, playbackChoices: resolved)
    }

    func hasPlaybackImports(for id: UUID) -> Bool {
        plannedDevice == id && playbackPreview?.imports.isEmpty == false
    }

    func prepare(_ device: ClassicDevice, library: LibraryStore, retry: Set<URL>? = nil,
                 playbackChoices: [String: PlaybackProgressSync.Selection] = [:]) async {
        guard !busy, !library.isScanning, !library.isScanningVideos, let root = library.libraryRoot else { return }
        PlayerEngine.shared.saveCurrentListening()
        playbackPreview = nil
        playbackConflict = nil
        busy = true
        plan = nil
        skipped = []
        previewPlayed = []
        previewWatched = []
        status = "Checking media for iPod compatibility…"
        defer { busy = false; progress = nil }

        let playback: PlaybackProgressSync
        let matches: [ListeningChange]
        do {
            let plays = try await Task.detached { try SyncEngine.readPlays(on: device.value, includeVideo: true) }.value
            guard root == library.libraryRoot, self.device(device.id) != nil else { return }
            matches = library.listeningChanges(plays.filter { $0.kind != .music }, includeMatching: true)
                .filter { match in retry == nil || library.url(forID: match.id).map { retry?.contains($0) == true } == true }
            let resolved = PlaybackProgressSync(root: root, matches: matches,
                                                baseline: playbackBaselines[device.value.settingsID] ?? [:], choices: playbackChoices)
            if !resolved.conflicts.isEmpty {
                playbackConflict = PlaybackConflictRequest(device: device.id, retry: retry, changes: resolved.conflicts)
                status = "Choose which playback progress to keep"
                return
            }
            playback = resolved
        } catch {
            status = "Could not read iPod playback progress"
            message = error.localizedDescription
            return
        }

        let selection = settings(for: device)
        let playlists = library.playlists + library.smartListsAsPlaylists()
        let playlistTracks = Set(playlists.filter { selection.playlists.contains($0.id.uuidString) }.flatMap(\.trackIDs))
        let eligible = library.tracks.filter { !selection.checkedOnly || library.isChecked($0.id) }
        let tracks = eligible.filter { track in
            selection.music && track.isMusic && (!selection.selectedMusic ||
                playlistTracks.contains(track.id) || selection.artists.contains(track.displayAlbumArtist) ||
                selection.albums.contains(track.classicAlbumKey) || selection.albums.contains(track.classicEditionKey) ||
                selection.genres.contains(track.genre) ||
                (selection.fillRemainingSpace == true && retry?.contains(root.appendingPathComponent(track.id)) == true))
        }
        let fillTracks = selection.music && selection.selectedMusic && selection.fillRemainingSpace == true && retry == nil
            ? eligible.filter { $0.isMusic } : []
        let selected = Set(tracks.map(\.id))
        let fillGroups = Dictionary(grouping: fillTracks, by: { $0.album.isEmpty ? $0.id : $0.classicEditionKey })
            .values.filter { $0.contains { !selected.contains($0.id) } }
            .sorted { first, second in
                let a = first.map(\.rating).max() ?? 0, b = second.map(\.rating).max() ?? 0
                return a == b ? first[0].id < second[0].id : a > b
            }
            .map { group in group.map { root.appendingPathComponent($0.id) } }
        let selectedURLs = Set(tracks.map { root.appendingPathComponent($0.id) })
        let fillURLs = Set(fillGroups.flatMap { $0 }).subtracting(selectedURLs)
        let retention = selection.podcastRetention ?? [:]
        let podcasts = selection.podcasts ? library.tracks.compactMap { track -> (URL, String)? in
            guard let show = track.podcastShow, selection.podcastNames.contains(show) else { return nil }
            let pinned = retention[show]?.pinned.contains(track.id) == true
            guard pinned || !selection.checkedOnly || library.isChecked(track.id) else { return nil }
            return (root.appendingPathComponent(track.id), show)
        } : []
        let audiobooks = selection.audiobooks ? eligible.compactMap { track -> (URL, String)? in
            guard let book = track.audiobookTitle, selection.audiobookNames.contains(book) else { return nil }
            return (root.appendingPathComponent(track.id), book)
        } : []
        let videoItems = library.videos
        let tvRules = selection.tvRetention ?? [:]
        let eligibleVideoIDs = Set(videoItems.filter { !selection.checkedOnly || library.isVideoChecked($0.id) }.map(\.id))
        let watchedLocally = Set(videoItems.filter {
            $0.kind == .tv && VideoWatchHistory.shared.state(at: library.url(forVideo: $0)).watched
        }.map(\.id))
        let videoEdits = Dictionary(uniqueKeysWithValues: videoItems.compactMap { item in
            let url = root.appendingPathComponent(item.id)
            return library.videoMetadata(for: url).map { (url, $0) }
        })
        var options = SyncOptions()
        let editions = Dictionary(grouping: library.tracks.filter(\.isMusic), by: \.classicAlbumKey)
        let ambiguousAlbums = Set(editions.compactMap { key, members in
            Set(members.map(\.classicEditionKey)).count > 1 ? key : nil
        })
        options.fillReserve = Int64(max(0, min(250, selection.reserveGB ?? 2))) * 1_000_000_000
        options.matchMusicByPath = Set((tracks + fillTracks).filter { ambiguousAlbums.contains($0.classicAlbumKey) }.map {
            root.appendingPathComponent($0.id)
        })
        do {
            let urls = Set(podcasts.map { $0.0 }).union(audiobooks.map { $0.0 })
            options.listening = Dictionary(uniqueKeysWithValues: library.tracks.compactMap { track in
                let url = root.appendingPathComponent(track.id)
                guard urls.contains(url), track.resumePosition != nil || track.finishedListening != nil else { return nil }
                return (url, ClassicListeningState(seconds: track.resumePosition ?? 0, played: track.finishedListening ?? false))
            })
        }
        if selection.tvShows || selection.movies {
            for item in videoItems {
                let url = root.appendingPathComponent(item.id)
                let state = VideoWatchHistory.shared.state(at: url)
                guard state.updated != .distantPast else { continue }
                options.listening[url] = ClassicListeningState(seconds: state.seconds, played: state.watched)
            }
        }
        // Existing matched items use the reconciled value. Source values are for new transfers.
        for match in matches {
            if let url = library.url(forID: match.id) { options.listening[url] = nil }
        }
        options.expectedListening = playback.expected
        options.existingListening = playback.desired
        options.artwork = true
        options.retrySources = retry
        options.excludedVideos = selection.excludedVideos ?? [:]
        options.useAlbumArtistForArtist = useAlbumArtistForArtist
        let excluded = Set((UserDefaults.standard.stringArray(forKey: "excludedClassicPlaylists") ?? []).compactMap(UUID.init(uuidString:)))
        options.playlists = playlists.filter {
            selection.music && !excluded.contains($0.id) && (!selection.selectedMusic || selection.playlists.contains($0.id.uuidString))
        }.map { item in
            var playlist = LocalPlaylist(name: item.name)
            playlist.id = item.id
            playlist.paths = item.trackIDs.filter(selected.contains).map { root.appendingPathComponent($0).path }
            return playlist
        }
        let playlistKey = "managedClassicPlaylists." + device.value.settingsID
        let previous = UserDefaults.standard.stringArray(forKey: playlistKey)
            ?? UserDefaults.standard.stringArray(forKey: "managedClassicPlaylists") ?? []
        let managedPlaylists = Set(previous.compactMap(UUID.init(uuidString:)))
        options.removedPlaylists = selection.music ? managedPlaylists.subtracting(
            (selection.selectedMusic ? options.playlists.map(\.id) : playlists.map(\.id))
        ) : []
        options.reconcileMusic = selection.music && selection.selectedMusic && selection.fillRemainingSpace != true
        if retry != nil {
            options.playlists = []
            options.removedPlaylists = []
            options.reconcileMusic = false
        }
        let generation = libraryGeneration
        let settings = options
        let retriedShows = Set(podcasts.filter { retry?.contains($0.0) == true }.map { $0.1 })
        let podcastsForRetention = Set(podcasts.filter {
            retriedShows.contains($0.1) && (retention[$0.1]?.limit != nil || retention[$0.1]?.unplayedOnly == true)
        }.map { $0.0 })
        let urls = (tracks.map { root.appendingPathComponent($0.id) } + podcasts.map { $0.0 }
                    + audiobooks.map { $0.0 } + Array(fillURLs)).filter { url in
            guard let retry else { return true }
            return retry.contains(url) || podcastsForRetention.contains(url)
        }
        let localPlayed = Set(library.tracks.filter { $0.finishedListening == true && $0.podcastShow != nil }
            .map { root.appendingPathComponent($0.id) })
        let podcastShows = Dictionary(podcasts, uniquingKeysWith: { first, _ in first })
        let bookTitles = Dictionary(audiobooks, uniquingKeysWith: { first, _ in first })
        let videoCache = LibraryStore.supportFolder.appendingPathComponent("Classic Videos", isDirectory: true)
        let cacheFile = LibraryStore.supportFolder.appendingPathComponent("ClassicCompatibility.plist")
        do {
            let (preview, skipped, watchedOnIPod) = try await Task.detached(priority: .userInitiated) {
                guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw SyncError("The media library folder is unavailable.")
                }
                let cache = LibraryCache.load(from: cacheFile)
                let checked = try await LibraryScanner.scanFiles(urls, cache: cache)
                if retry == nil { try? LibraryCache(folders: [root], library: checked).save(to: cacheFile) }
                let refreshedDates = await PodcastFeed.refreshReleaseDates(for: urls.filter { podcastShows[$0] != nil })
                var syncOptions = settings
                let failedURLs = Set((checked.failures ?? []).filter { $0.reason != "Unsupported audio file type." }.map(\.url))
                if tracks.contains(where: { failedURLs.contains(root.appendingPathComponent($0.id)) }) {
                    syncOptions.reconcileMusic = false
                }
                syncOptions.playedPodcastURLs = localPlayed
                let failedShows = Set(failedURLs.compactMap { podcastShows[$0] })
                for show in selection.podcastNames where selection.podcasts {
                    guard let policy = retention[show], policy.unplayedOnly == true || policy.limit != nil else { continue }
                    syncOptions.podcastLimits[show] = PodcastSyncLimit(
                        latest: policy.limit ?? Int.max, pinned: Set(policy.pinned.map { root.appendingPathComponent($0) }),
                        removeOlder: retry == nil && policy.limit != nil && !failedShows.contains(show),
                        removePlayed: retry == nil && policy.unplayedOnly == true && !failedShows.contains(show),
                        unplayed: policy.unplayedOnly == true
                    )
                }
                let scanned = Dictionary(checked.songs.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
                syncOptions.fillAlbums = fillGroups.compactMap { group in
                    let songs = group.compactMap { scanned[$0] }
                    return songs.count == group.count ? songs.filter { !selectedURLs.contains($0.url) } : nil
                }
                var media = checked.songs.filter { !fillURLs.contains($0.url) }.map { song -> Song in
                    if let show = podcastShows[song.url] {
                        return LibraryScanner.podcast(song, show: show, metadata: refreshedDates[song.url])
                    }
                    if let book = bookTitles[song.url] { return LibraryScanner.audiobook(song, book: book) }
                    return song
                }
                var skipped = (checked.failures ?? []).filter { retry?.contains($0.url) ?? true }.map { failure in
                    var item = SyncItem(.skip, failure.url.deletingPathExtension().lastPathComponent, failure.reason)
                    if failure.reason != "Unsupported audio file type." { item.sourceURL = failure.url }
                    return item
                }
                if settings.reconcileMusic && !syncOptions.reconcileMusic {
                    skipped.append(SyncItem(.skip, "Music removals", "Some selected songs could not be read."))
                }
                skipped += failedShows.sorted().filter { syncOptions.podcastLimits[$0] != nil }.map {
                    SyncItem(.skip, $0, "Older iPod copies were kept because some selected episodes could not be read.")
                }
                let automaticShows = Set(tvRules.compactMap { show, rule in
                    selection.tvShows && rule.limit != nil && selection.showNames.contains(show) ? show : nil
                })
                let deviceWatched = automaticShows.isEmpty ? [] :
                    try SyncEngine.readPlays(on: device.value, includeVideo: true).filter { $0.kind == .tvShow && $0.played }
                let watchedKeys = Set(deviceWatched.compactMap(\.videoSyncKey))
                if !automaticShows.isEmpty { syncOptions.expectedWatchedTVKeys = watchedKeys }
                let tvGroups = Dictionary(grouping: videoItems.filter { $0.kind == .tv }, by: \.show)
                var automaticIDs = Set<String>()
                var watchedOnIPod = Set<URL>()
                for show in automaticShows {
                    guard let rule = tvRules[show], let limit = rule.limit else { continue }
                    let episodes = (tvGroups[show] ?? []).sorted(by: VideoItem.episodeOrder)
                    let eligible = episodes.filter { episode in
                        let onDevice = watchedKeys.contains(episode.classicTVKey)
                        if onDevice, !watchedLocally.contains(episode.id) {
                            watchedOnIPod.insert(root.appendingPathComponent(episode.id))
                        }
                        return eligibleVideoIDs.contains(episode.id) && selection.includesTVEpisode(episode)
                            && !onDevice && !watchedLocally.contains(episode.id) && !rule.pinned.contains(episode.id)
                    }
                    let wanted = Set(eligible.prefix(max(0, min(100, limit))).map(\.id)).union(rule.pinned)
                    let distinctEpisodes = Dictionary(grouping: episodes, by: \.classicTVKey).filter { $0.value.count == 1 }
                    automaticIDs.formUnion(wanted)
                    if retry == nil {
                        syncOptions.retainedTVKeys.formUnion(episodes.filter { wanted.contains($0.id) }.map(\.classicTVKey))
                        syncOptions.expiredTVKeys.formUnion(distinctEpisodes.values.compactMap { versions in
                            versions.first.flatMap { wanted.contains($0.id) ? nil : $0.classicTVKey }
                        })
                    }
                }
                let videosToPrepare = videoItems.compactMap { item -> ClassicVideo? in
                    let url = root.appendingPathComponent(item.id)
                    guard retry?.contains(url) ?? true else { return nil }
                    if item.kind == .tv {
                        guard selection.tvShows, !item.show.isEmpty else { return nil }
                        if automaticShows.contains(item.show) {
                            guard automaticIDs.contains(item.id) else { return nil }
                        } else {
                            guard eligibleVideoIDs.contains(item.id), selection.includesTVEpisode(item) else { return nil }
                        }
                    } else {
                        guard eligibleVideoIDs.contains(item.id), selection.movies, selection.movieIDs.contains(item.id) else { return nil }
                    }
                    return ClassicVideo(url: url, title: item.title, show: item.kind == .tv ? item.show : "",
                                        season: item.season, episode: item.episode, year: item.year)
                }
                for (index, video) in videosToPrepare.enumerated() {
                    await MainActor.run {
                        self.status = "Preparing video \(index + 1) of \(videosToPrepare.count) · \(video.title)"
                        self.progress = Double(index) / Double(videosToPrepare.count)
                    }
                    do {
                        let song = try await ClassicVideoConversion.prepare(video, cache: videoCache)
                        media.append(song.applyingVideoEdit(videoEdits[video.url]))
                    }
                    catch {
                        if automaticShows.contains(video.show) {
                            syncOptions.expiredTVKeys.subtract((tvGroups[video.show] ?? []).map(\.classicTVKey))
                        }
                        var item = SyncItem(.skip, videoEdits[video.url]?.title ?? video.title, error.localizedDescription)
                        item.sourceURL = video.url
                        skipped.append(item)
                    }
                }
                return (try SyncEngine.preview(media, on: device.value, options: syncOptions), skipped, watchedOnIPod)
            }.value
            guard generation == libraryGeneration, !library.isScanning, !library.isScanningVideos,
                  self.device(device.id) != nil else {
                status = "Library or device changed. Preview sync again."
                return
            }
            let remembered = Set(previous).union(settings.playlists.map { $0.id.uuidString })
            UserDefaults.standard.set(remembered.sorted(), forKey: playlistKey)
            previewPlayed = preview.playedPodcastSources.subtracting(localPlayed)
            previewWatched = watchedOnIPod

            plannedDevice = device.id
            playbackPreview = playback
            let hasImports = !playback.imports.isEmpty
            plan = preview.hasChanges || hasImports || !preview.items.isEmpty || !skipped.isEmpty ? preview : nil
            self.skipped = skipped
            if preview.hasChanges || hasImports {
                status = !preview.hasChanges || preview.canFit ? "Sync preview ready" : "Not enough free space to apply this preview"
            } else {
                status = plan == nil ? "iPod library is up to date" : "No changes to apply · See preview details"
                if !skipped.isEmpty { saveReport(for: device, items: skipped + preview.items) }
                savePlaybackBaseline(device, states: playback.expected)
            }
        } catch {
            message = error.localizedDescription
            status = "Could not preview sync"
        }
    }

    private func savePlaybackBaseline(_ device: ClassicDevice, states: [Data: ClassicListeningState]) {
        var entries = playbackBaselines[device.value.settingsID] ?? [:]
        for (id, state) in states { entries[id.base64EncodedString()] = state }
        playbackBaselines[device.value.settingsID] = entries
        if let data = try? JSONEncoder().encode(playbackBaselines) {
            UserDefaults.standard.set(data, forKey: "iPodPlaybackBaselines")
        }
    }

    struct Backup: Identifiable {
        let id: URL
        let date: Date
    }

    private var backupsFolder: URL { LibraryStore.supportFolder.appendingPathComponent("Backups") }

    func backups(for device: ClassicDevice) -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsFolder,
                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        return files.compactMap { url -> Backup? in
            let name = url.deletingPathExtension().lastPathComponent
            let prefix = "iTunesDB-" + device.value.settingsID + "-"
            let suffix = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : String(name.dropFirst("iTunesDB-".count))
            guard url.pathExtension == "backup", name.hasPrefix("iTunesDB-"), UUID(uuidString: suffix) != nil,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let date = values.contentModificationDate else { return nil }
            return Backup(id: url, date: date)
        }.sorted { $0.date > $1.date }
    }

    func reviewRestore(_ backup: Backup, for device: ClassicDevice) async -> ClassicRestorePreview? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let preview = try await Task.detached { try SyncEngine.previewRestore(backup.id, on: device.value) }.value
            return self.device(device.id) == nil ? nil : preview
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func restore(_ preview: ClassicRestorePreview) async {
        guard !busy else { return }
        busy = true
        discardPreview()
        status = "Restoring iPod database…"
        let folder = backupsFolder
        defer { busy = false }
        do {
            try await Task.detached { try SyncEngine.restore(preview, backups: folder) }.value
            status = "Restored iPod database"
            await refresh()
        } catch {
            status = "Could not restore iPod database"
            message = error.localizedDescription
        }
    }

    func retryFailures(_ device: ClassicDevice, library: LibraryStore, report: DeviceSyncReport) async {
        guard !busy, !library.isScanning, !library.isScanningVideos, library.libraryRoot != nil else { return }
        let sources = Set(report.items.filter { $0.action == .skip }.compactMap(\.sourceURL))
        guard !sources.isEmpty else { return }
        await prepare(device, library: library, retry: sources)
        if !busy, plan == nil, status == "iPod library is up to date" {
            status = "No failed items still need syncing under this iPod’s current settings."
        }
    }

    func previewDefaultPlaylistRemoval(_ device: ClassicDevice, library: LibraryStore) async {
        var options = SyncOptions()
        options.removeDefaultPlaylists = true
        options.protectedPlaylists = Set((library.playlists + library.smartListsAsPlaylists()).map(\.id))
        await previewRemoval(device, options: options)
    }

    func previewVideoRemoval(_ device: ClassicDevice, items: [ClassicDeviceItem], exclude: Bool = false) async {
        var options = SyncOptions()
        options.removedVideoIDs = Set(items.map(\.persistentID))
        if exclude {
            options.videoExclusionsToSave = Dictionary(items.map { ($0.syncKey, $0.album.isEmpty ? $0.title : "\($0.album) · \($0.title)") },
                                                       uniquingKeysWith: { first, _ in first })
        }
        await previewRemoval(device, options: options)
    }

    private func previewRemoval(_ device: ClassicDevice, options: SyncOptions) async {
        playbackPreview = nil
        previewPlayed = []
        previewWatched = []
        guard !busy else { return }
        busy = true
        plan = nil
        skipped = []
        status = "Checking items on the iPod…"
        defer { busy = false }
        let settings = options
        let generation = libraryGeneration
        do {
            let preview = try await Task.detached {
                try SyncEngine.preview([], on: device.value, options: settings)
            }.value
            guard self.device(device.id) != nil, generation == libraryGeneration else {
                status = "Library or device changed. Preview again."
                return
            }
            if preview.hasChanges {
                plannedDevice = device.id
                plan = preview
                status = "Removal preview ready"
            } else {
                status = "No matching items on the iPod"
            }
        } catch {
            status = "Could not preview removal"
            message = error.localizedDescription
        }
    }

    func sync(_ device: ClassicDevice) async {
        guard !busy, let plan = preview(for: device.id),
              (plan.hasChanges && plan.canFit) || (!plan.hasChanges && hasPlaybackImports(for: device.id)) else { return }
        let playback = playbackPreview
        let library = LibraryStore.shared
        if let playback {
            guard playback.root == library.libraryRoot,
                  playback.matches.allSatisfy({ library.isCurrentListening($0) }) else {
                discardPreview()
                status = "Mac playback progress changed. Preview Sync again."
                return
            }
        }
        busy = true
        status = "Preparing transfer…"
        progress = 0
        canStop = true
        let stop = SyncStop()
        self.stop = stop
        let backups = LibraryStore.supportFolder.appendingPathComponent("Backups")
        let skipped = self.skipped
        let played = previewPlayed
        let watched = previewWatched
        defer {
            busy = false
            canStop = false
            progress = nil
            self.stop = nil
            self.plan = nil
            playbackPreview = nil
        }
        do {
            let updates = AsyncStream.makeStream(of: (Int, Int, String).self, bufferingPolicy: .bufferingNewest(1))
            let work = Task.detached(priority: .userInitiated) { [weak self] in
                defer { updates.continuation.finish() }
                var report: [SyncItem] = []
                if !plan.hasChanges {
                    try SyncEngine.validatePlaybackSnapshot(plan)
                    return (0, report)
                }
                let count = try SyncEngine.apply(plan, backups: backups, stop: stop, notice: { [weak self] notice in
                    Task { @MainActor in self?.message = notice }
                }, report: { report = $0 }) { current, total, title in
                    updates.continuation.yield((current, total, title))
                }
                return (count, report)
            }
            for await (current, total, title) in updates.stream {
                progress = total > 0 ? Double(current) / Double(total) : nil
                if title == "Saving iTunesDB…" {
                    canStop = false
                    status = title
                } else if !stop.isRequested {
                    let action = plan.isVideoReplacement(at: current) ? "Replacing" : "Copying"
                    status = title == "Preparing artwork…"
                        ? "\(title) \(current.formatted()) of \(total.formatted())"
                        : "\(action) \((current + 1).formatted()) of \(total.formatted()) · \(title)"
                }
            }
            let (count, deviceReport) = try await work.value
            var report = deviceReport
            if !plan.videoExclusions.isEmpty, report.contains(where: { $0.action == .remove }) {
                var updated = settings(for: device)
                updated.excludedVideos = (updated.excludedVideos ?? [:]).merging(plan.videoExclusions) { _, new in new }
                setSettings(updated, for: device)
            }
            if let playback, !stop.isRequested, playback.root == library.libraryRoot,
               !report.contains(where: { $0.action == .skip && ["iPod database", "iPod Play Counts"].contains($0.title) }) {
                let imports = playback.imports.filter { library.isCurrentListening($0) }
                library.applyListeningChanges(imports)
                report += imports.map { SyncItem(.metadata, $0.title, "Imported playback progress from iPod") }
                if let actual = try? await Task.detached(operation: { try SyncEngine.readPlays(on: device.value, includeVideo: true) }).value {
                    let current = library.listeningChanges(actual.filter { $0.kind != .music }, includeMatching: true)
                    let agreed = Dictionary(current.filter { $0.macState.matches($0.iPodState) }.map {
                        ($0.play.id, $0.iPodState)
                    }, uniquingKeysWith: { a, _ in a })
                    if playback.root == library.libraryRoot { savePlaybackBaseline(device, states: agreed) }
                }
            }
            let reconciled = Set(playback?.matches.compactMap { library.url(forID: $0.id) } ?? [])
            if !stop.isRequested, !played.isEmpty, !report.contains(where: { $0.title == "iPod database" && $0.action == .skip }) {
                let library = LibraryStore.shared
                for track in library.tracks where library.url(for: track).map { played.contains($0) && !reconciled.contains($0) } == true {
                    library.saveListening(track.id, position: 0, finished: true)
                }
            }
            if !stop.isRequested, !report.contains(where: { $0.title == "iPod database" && $0.action == .skip }) {
                for url in watched where !reconciled.contains(url) && !VideoWatchHistory.shared.state(at: url).watched {
                    VideoWatchHistory.shared.update(url, seconds: 0, duration: 0, watched: true)
                }
            }
            let replaced = plan.videoReplacements(inCompletedTransfers: count)
            let added = count - replaced
            let removed = report.filter { $0.action == .remove }.count
            let changes = [
                added > 0 ? "\(added.formatted()) added" : nil,
                replaced > 0 ? "\(replaced.formatted()) replaced" : nil,
                removed > 0 ? "\(removed.formatted()) removed" : nil
            ].compactMap { $0 }.joined(separator: " · ")
            if stop.isRequested {
                status = changes.isEmpty ? "Stopped" : "Stopped · " + changes
            } else {
                status = changes.isEmpty ? "iPod library updated" : "Synced · " + changes
            }
            saveReport(for: device, items: report + skipped)
        } catch {
            message = error.localizedDescription
            status = "Sync stopped"
            saveReport(for: device, items: skipped + plan.items.map { planned in
                var item = SyncItem(.skip, planned.title, error.localizedDescription)
                item.sourceURL = planned.sourceURL
                return item
            })
        }
        await refresh()
    }

    func stopAndSave() {
        guard canStop else { return }
        stop?.request()
        canStop = false
        status = "Stopping and saving copied tracks…"
    }

    func eject(_ device: ClassicDevice) {
        guard !busy else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: device.value.mount)
            Task { await refresh() }
        } catch {
            message = error.localizedDescription
        }
    }
}
