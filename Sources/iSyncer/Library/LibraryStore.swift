import ClassicSync
import Foundation
import Combine
import CryptoKit

/// The library: tracks, checkboxes, playlists. Persisted as JSON in Application Support.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    private let storageFolder: URL?

    init(storageFolder: URL? = nil) { self.storageFolder = storageFolder }

    /// Canonically sorted (album artist, album, disc, track).
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    /// Smart playlists made in the app (the four built-in ones are separate).
    @Published private(set) var smartLists: [SmartPlaylist] = []
    /// iTunes-style checkboxes. Most songs are checked, so only the exceptions are stored.
    @Published private(set) var unchecked: Set<String> = []
    /// Anchor for legacy relative IDs; retained when its source is removed so other IDs stay stable.
    @Published private(set) var libraryRoot: URL?
    @Published private(set) var libraryFolders: [URL] = []
    var downloadFolder: URL? { libraryFolders.first }

    func folder(containing url: URL) -> URL? {
        libraryFolders.first { LibraryFolders.contains($0, url) }
    }

    func mediaID(for url: URL) -> String? {
        guard let folder = folder(containing: url), let root = libraryRoot else { return nil }
        return folder.path == root.path ? Scanner.relativePath(of: url, rootPath: root.standardizedFileURL.path) : url.standardizedFileURL.path
    }

    var foldersBusy: Bool {
        isScanning || isScanningVideos || DeviceManager.shared.busy ||
            PodcastSubscriptions.shared.downloading || PodcastSubscriptions.shared.checking || LoudnessAnalyzer.shared.running ||
            LibraryBackupController.shared.busy
    }

    func addFolders(_ urls: [URL]) throws {
        guard !foldersBusy else { throw ShellError(message: "Wait for the current library operation to finish.") }
        let updated = try LibraryFolders.adding(urls, to: libraryFolders)
        guard updated != libraryFolders else { return }
        if libraryRoot == nil { libraryRoot = updated.first }
        libraryFolders = updated
        saveNowBlocking()
        scan()
    }

    func removeFolder(_ url: URL) throws {
        guard !foldersBusy else { throw ShellError(message: "Wait for the current library operation to finish.") }
        guard libraryFolders.contains(where: { $0.path == url.path }), let anchor = libraryRoot else { return }
        if self === Self.shared { PlayerEngine.shared.saveCurrentListening() }
        let removed = Set(tracks.filter { LibraryFolders.contains(url, anchor.appendingLibraryPath($0.id)) }.map(\.id))
        let removedVideos = Set(videos.filter { LibraryFolders.contains(url, anchor.appendingLibraryPath($0.id)) }.map(\.id))
        if self === Self.shared, let current = PlayerEngine.shared.current, removed.contains(current.id) { PlayerEngine.shared.stop() }
        tracks.removeAll { removed.contains($0.id) }
        videos.removeAll { removedVideos.contains($0.id) }
        unchecked.subtract(removed)
        uncheckedVideos.subtract(removedVideos)
        episodeSources = episodeSources.filter { !removedVideos.contains($0.key) }
        missingRelinkPaths = missingRelinkPaths.filter { !LibraryFolders.contains(url, anchor.appendingLibraryPath($0)) }
        missingRelinkTracks = missingRelinkTracks.filter { !LibraryFolders.contains(url, anchor.appendingLibraryPath($0.key)) }
        playlists.removeAll { $0.importedFrom.map { LibraryFolders.contains(url, anchor.appendingLibraryPath($0)) } == true }
        playlists = playlists.map { value in
            var value = value
            value.trackIDs.removeAll { removed.contains($0) }
            return value
        }
        libraryFolders.removeAll { $0.path == url.path }
        if libraryFolders.isEmpty { libraryRoot = nil }
        rebuildIndex()
        videoMetadataRevision += 1
        DeviceManager.shared.collectionDidChange()
        saveNowBlocking()
    }
    @Published private(set) var isScanning = false
    @Published private(set) var missingRelinkPaths: Set<String> = []
    @Published private(set) var scanStatus = ""
    /// Videos found in the media library (TV / Movies / …), synced in the layout Y2-Rockbox indexes.
    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var uncheckedVideos: Set<String> = []
    @Published private(set) var isScanningVideos = false
    @Published private(set) var videoMetadataRevision = 0

    private var legacyVideoRoots: [URL] = []
    private var missingRelinkTracks: [String: Track] = [:]
    private struct EpisodeSource: Codable {
        let url: URL
        let size: Int
        let date: Date

        @MainActor var transfer: EpisodeTransferIdentity {
            ClassicVideoConversion.transferIdentity(for: url, size: size, date: date,
                in: ConversionCache.defaultVideo(in: LibraryStore.supportFolder))
        }
    }

    private var episodeSources: [String: [EpisodeSource]] = [:]
    private var videoMetadataLocations: [String: URL] = [:]
    private var videoMetadataScannedIDs = Set<String>()
    private var videoMetadataStore: VideoMetadataStore {
        VideoMetadataStore(folder: (storageFolder ?? Self.supportFolder).appendingPathComponent("Video Metadata", isDirectory: true))
    }

    private var index: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?
    private var devicePlayTotals: [String: Int] = [:]
    private var replacedTrackPaths: [String: String] = [:]
    private let saveQueue = DispatchQueue(label: "iSyncer.LibrarySave")

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("iSyncer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var libraryFile: URL { (storageFolder ?? Self.supportFolder).appendingPathComponent("library.json") }

    private struct Saved: Codable {
        var root: String?
        var folders: [URL]? = nil
        var tracks: [Track]
        var playlists: [Playlist]
        var unchecked: [String]
        var videoRoot: String?
        var videos: [VideoItem]?
        var uncheckedVideos: [String]?
        var smartLists: [SmartPlaylist]?
        var devicePlayTotals: [String: Int]? = nil
        var replacedTrackPaths: [String: String]? = nil
        var missingRelinkPaths: Set<String>? = nil
        var missingRelinkTracks: [String: Track]? = nil
        var legacyVideoRoots: [URL]? = nil
        var episodeSources: [String: [EpisodeSource]]? = nil
    }

    // MARK: Load / save

    nonisolated static func validateBackup(_ data: Data) throws {
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard Set(saved.tracks.map(\.id)).count == saved.tracks.count else {
            throw ShellError(message: "The backup contains duplicate track identifiers.")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            migratePreviousLibrary()
            return
        }
        libraryRoot = saved.root.map { URL(fileURLWithPath: $0, isDirectory: true) }
        libraryFolders = saved.folders ?? libraryRoot.map { [$0] } ?? []
        videoMetadataLocations = [:]
        videoMetadataScannedIDs = []
        videoMetadataRevision += 1
        tracks = saved.tracks
        playlists = saved.playlists
        unchecked = Set(saved.unchecked)
        videos = saved.videos ?? []
        uncheckedVideos = Set(saved.uncheckedVideos ?? [])
        smartLists = saved.smartLists ?? []
        devicePlayTotals = saved.devicePlayTotals ?? [:]
        replacedTrackPaths = saved.replacedTrackPaths ?? [:]
        missingRelinkPaths = saved.missingRelinkPaths ?? []
        missingRelinkTracks = saved.missingRelinkTracks ?? [:]
        legacyVideoRoots = saved.legacyVideoRoots ?? []
        episodeSources = saved.episodeSources ?? [:]
        rebuildIndex()
    }

    private func migratePreviousLibrary() {
        let defaults = UserDefaults.standard
        guard let path = defaults.stringArray(forKey: "musicFolders")?.first else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        libraryRoot = root
        libraryFolders = [root]
        let prefix = root.path + "/"
        let rockboxFile = Self.supportFolder.deletingLastPathComponent()
            .appending(path: "RockboxSync/library.json")
        if let data = try? Data(contentsOf: rockboxFile),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), let oldPath = saved.root {
            let oldRoot = URL(fileURLWithPath: oldPath, isDirectory: true)
            tracks = saved.tracks.compactMap { old in
                let url = oldRoot.appendingPathComponent(old.id).standardizedFileURL
                guard url.path.hasPrefix(prefix) else { return nil }
                var track = old
                track.id = String(url.path.dropFirst(prefix.count))
                return track
            }
        }
        if let data = defaults.data(forKey: "localPlaylists"),
           let previous = try? JSONDecoder().decode([LocalPlaylist].self, from: data) {
            for playlist in previous {
                if let rules = playlist.rules {
                    var list = SmartPlaylist()
                    list.id = playlist.id
                    list.name = playlist.name
                    list.matchAll = playlist.matchAll
                    list.limitEnabled = playlist.limit != nil
                    list.limitCount = Double(playlist.limit ?? 25)
                    list.selectedBy = .libraryOrder
                    list.rules = rules.map(SmartRule.init(previousRule:))
                    smartLists.append(list)
                } else {
                    playlists.append(Playlist(id: playlist.id, name: playlist.name,
                                              trackIDs: playlist.paths.filter { $0.hasPrefix(prefix) }
                                                  .map { String($0.dropFirst(prefix.count)) },
                                              importedFrom: nil))
                }
            }
            defaults.set(previous.filter { !$0.sync }.map { $0.id.uuidString }, forKey: "excludedClassicPlaylists")
            let removed = defaults.stringArray(forKey: "removedPlaylists") ?? []
            defaults.set(previous.map { $0.id.uuidString } + removed, forKey: "managedClassicPlaylists")
        }
        rebuildIndex()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let saved = makeSaved()
        let url = libraryFile
        saveQueue.async {
            if let data = try? JSONEncoder().encode(saved) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Synchronous save, used at quit so nothing is lost.
    func saveNowBlocking() {
        saveTask?.cancel()
        let saved = makeSaved()
        let url = libraryFile
        saveQueue.sync {
            if let data = try? JSONEncoder().encode(saved) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func makeSaved() -> Saved {
        Saved(root: libraryRoot?.path, folders: libraryFolders, tracks: tracks, playlists: playlists, unchecked: Array(unchecked),
              videoRoot: nil, videos: videos, uncheckedVideos: Array(uncheckedVideos), smartLists: smartLists,
              devicePlayTotals: devicePlayTotals, replacedTrackPaths: replacedTrackPaths,
              missingRelinkPaths: missingRelinkPaths, missingRelinkTracks: missingRelinkTracks, legacyVideoRoots: legacyVideoRoots, episodeSources: episodeSources)
    }

    // MARK: Videos

    func scanVideos() {
        guard let root = libraryRoot, !isScanningVideos else { return }
        isScanningVideos = true
        let store = self
        let metadata = videoMetadataStore
        let previous = videos
        let legacyRoots = legacyVideoRoots
        let folders = libraryFolders
        Task.detached(priority: .userInitiated) {
            var found: [VideoItem] = []
            var unavailable = Set<String>()
            for folder in folders {
                if LibraryFolders.available(folder) {
                    found += VideoScanner.scan(root: folder, absoluteIDs: folder.path != root.path)
                } else {
                    let prior = previous.filter { LibraryFolders.contains(folder, root.appendingLibraryPath($0.id)) }
                    found += prior
                    unavailable.formUnion(prior.map(\.id))
                }
            }
            let locations = metadata.resolve(found.filter { !unavailable.contains($0.id) }, root: root,
                                             previous: previous, legacyRoots: legacyRoots)
            let snapshot = found
            let missing = unavailable
            await MainActor.run {
                store.videoMetadataLocations.merge(locations, uniquingKeysWith: { _, new in new })
                store.videos = snapshot
                let ids = Set(snapshot.map(\.id))
                store.videoMetadataScannedIDs = ids.subtracting(missing)
                store.missingRelinkPaths.subtract(ids.subtracting(missing))
                store.missingRelinkPaths.formUnion(missing)
                store.videoMetadataRevision += 1
                store.uncheckedVideos.formIntersection(ids.union(store.missingRelinkPaths))
                store.isScanningVideos = false
                store.scheduleSave()
            }
        }
    }

    func url(forVideo v: VideoItem) -> URL? { libraryRoot?.appendingLibraryPath(v.id) }

    func rememberedTVMatch(for show: String) -> VideoDirectory.Match? {
        guard let key = tvMatchKey(for: show), let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VideoDirectory.Match.self, from: data)
    }

    func rememberTVMatch(_ match: VideoDirectory.Match, for show: String) {
        guard let key = tvMatchKey(for: show), let data = try? JSONEncoder().encode(match) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func tvMatchKey(for show: String) -> String? {
        guard let root = libraryRoot, !show.isEmpty else { return nil }
        let key = "\(root.standardizedFileURL.path)\0\(show)".precomposedStringWithCanonicalMapping
        return "tmdbShowMatch." + SHA256.hash(data: Data(key.utf8)).description
    }

    func videoMetadata(for url: URL) -> VideoMetadataEdit? {
        let metadata = videoMetadataStore
        let id = mediaID(for: url)
        if let id {
            if let location = videoMetadataLocations[id] { return metadata.read(location) }
            if videoMetadataScannedIDs.contains(id) { return nil }
        }
        return metadata.read(metadata.legacyLocation(for: url))
    }

    func saveVideoMetadata(_ metadata: VideoMetadataEdit, for url: URL) throws {
        try writeVideoMetadata(metadata, for: url)
        videoMetadataRevision += 1
    }

    func episodeCorrections() -> [EpisodeCorrection] {
        videos.compactMap { item in
            guard let history = episodeSources[item.id], let prior = history.last,
                  let url = url(forVideo: item),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let date = values.contentModificationDate,
                  prior.size == size, prior.date == date else { return nil }
            let current = EpisodeSource(url: url, size: size, date: date)
            return EpisodeCorrection(target: url, season: item.season, episode: item.episode,
                                     transfers: (history + [current]).map(\.transfer))
        }
    }

    func renumberEpisode(_ draft: VideoItem, season: Int, episode: Int, saving metadata: VideoMetadataEdit) throws {
        try organizeEpisodes([EpisodeNumberEdit(video: draft, season: season, episode: episode)], metadata: metadata)
    }

    func planEpisodeMoves(_ edits: [EpisodeNumberEdit]) throws -> [PlannedEpisodeMove] {
        guard let root = libraryRoot else { throw SyncError("Choose a media library first.") }
        return try EpisodeNumberEdit.plan(edits, videos: videos, root: root, additionalRoots: libraryFolders)
    }

    func organizeEpisodes(_ edits: [EpisodeNumberEdit], metadata: VideoMetadataEdit? = nil) throws {
        guard !isScanning, !isScanningVideos, !DeviceManager.shared.busy, let root = libraryRoot else {
            throw SyncError("Wait for the current scan or sync to finish.")
        }
        let plan = try planEpisodeMoves(edits)
        guard !plan.isEmpty else { return }
        let sources = try plan.map { move in
            let values = try move.files.source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let date = values.contentModificationDate,
                  Int64(size) == move.previous.size, date.timeIntervalSince1970 == move.previous.modified else {
                throw SyncError("The episode file changed. Rescan the library and try again.")
            }
            return EpisodeSource(url: move.files.source, size: size, date: date)
        }
        let edits = plan.map { move in metadata ?? videoMetadata(for: move.files.source) }
        try EpisodeMove.perform(plan.map(\.files), in: root, additionalRoots: libraryFolders) {
            for (move, edit) in zip(plan, edits) {
                if let edit { try writeVideoMetadata(edit, for: move.files.destination, retireLegacy: false) }
            }
        }
        let prior = episodeSources
        let oldUnchecked = uncheckedVideos
        let oldIDs = Set(plan.map { $0.previous.id })
        episodeSources = episodeSources.filter { !oldIDs.contains($0.key) }
        uncheckedVideos.subtract(oldIDs)
        videoMetadataLocations = videoMetadataLocations.filter { !oldIDs.contains($0.key) }
        for (move, source) in zip(plan, sources) {
            episodeSources[move.updated.id] = (prior[move.previous.id] ?? []) + [source]
            if oldUnchecked.contains(move.previous.id) { uncheckedVideos.insert(move.updated.id) }
            try? FileManager.default.removeItem(at: videoMetadataStore.legacyLocation(for: move.files.source))
        }
        VideoWatchHistory.shared.move(plan.map(\.files))
        DeviceManager.shared.moveEpisodeSettings(plan)
        let replacements = Dictionary(uniqueKeysWithValues: plan.map { ($0.previous.id, $0.updated) })
        videos = videos.map { replacements[$0.id] ?? $0 }
        videoMetadataRevision += 1
        scanVideos()
        saveNowBlocking()
    }

    func saveEpisodeMetadata(_ updates: [VideoDirectory.EpisodeUpdate]) -> (saved: Set<VideoItem.ID>, error: String?) {
        var saved = Set<VideoItem.ID>()
        defer { if !saved.isEmpty { videoMetadataRevision += 1 } }
        let current = Set(videos.map(\.id))
        for update in updates {
            guard current.contains(update.id), let url = url(forVideo: update.video), let incoming = update.metadata else {
                return (saved, "An episode is no longer in the media library.")
            }
            var edit = videoMetadata(for: url) ?? VideoMetadataEdit()
            if let title = incoming.title, !title.isEmpty { edit.title = title }
            if let date = incoming.releaseDate {
                edit.releaseDate = date
                edit.resetReleaseDate = nil
            }
            if let artwork = incoming.artwork {
                edit.artwork = artwork
                edit.resetArtwork = nil
            }
            if let overview = incoming.overview { edit.overview = overview }
            do {
                try writeVideoMetadata(edit, for: url)
                saved.insert(update.id)
            } catch {
                return (saved, "Could not save \(update.video.displayTitle). \(error.localizedDescription)")
            }
        }
        return (saved, nil)
    }

    private func writeVideoMetadata(_ metadata: VideoMetadataEdit, for url: URL, retireLegacy: Bool = true) throws {
        guard !isScanningVideos,
              let id = mediaID(for: url),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw SyncError("Wait for the video scan to finish and try again.")
        }
        let storage = videoMetadataStore
        let destination = try storage.contentLocation(for: url, size: Int64(size))
        try storage.save(metadata, at: destination)
        if retireLegacy {
            try? FileManager.default.removeItem(at: storage.legacyLocation(for: url))
            videoMetadataLocations[id] = destination
        }
    }

    func isVideoChecked(_ id: String) -> Bool { !uncheckedVideos.contains(id) }

    func setVideosChecked(_ ids: [String], _ checked: Bool) {
        var set = uncheckedVideos
        if checked { set.subtract(ids) } else { set.formUnion(ids) }
        uncheckedVideos = set
        scheduleSave()
    }

    private func rebuildIndex() {
        index = Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Lookup

    func track(_ id: String) -> Track? {
        guard let i = index[id] else { return nil }
        return tracks[i]
    }

    func url(for track: Track) -> URL? {
        libraryRoot?.appendingLibraryPath(track.id)
    }

    func url(forID id: String) -> URL? {
        libraryRoot?.appendingLibraryPath(id)
    }

    func isChecked(_ id: String) -> Bool { !unchecked.contains(id) }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { track($0) }
    }

    func playlist(_ id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: Scanning

    func setRoot(_ url: URL) {
        guard !foldersBusy else { return }
        // The legacy chooser still supports broadening a single root. With several sources,
        // adding folders must use the explicit list instead of discarding other locations.
        if libraryFolders.count > 1 || libraryFolders.first != libraryRoot && !libraryFolders.isEmpty {
            try? addFolders([url])
            return
        }
        if url != libraryRoot {
            videoMetadataLocations = [:]
            videoMetadataScannedIDs = []
            missingRelinkPaths = []
            missingRelinkTracks = [:]
            legacyVideoRoots = []
        }
        if let old = libraryRoot { migrate(from: old, to: url) }
        libraryRoot = url
        libraryFolders = [url]
        scheduleSave()
        scan()
    }

    private var relinkPaths: Set<String> {
        Set(tracks.map(\.id)).union(videos.map(\.id)).union(missingRelinkPaths).filter { !$0.hasPrefix("/") }
    }

    func previewRelink(_ url: URL) async throws -> LibraryRelink {
        guard !isScanning, !isScanningVideos, !DeviceManager.shared.busy, let source = libraryRoot else {
            throw SyncError("Finish the current operation before relinking the library.")
        }
        guard libraryFolders.contains(source) else {
            throw SyncError("The original folder is no longer a library source. Manage the remaining folders in Settings → Library.")
        }
        _ = try LibraryFolders.adding([url], to: libraryFolders.filter { $0 != source })
        let paths = relinkPaths
        return try await Task.detached {
            try LibraryRelink.inspect(source: source, destination: url.standardizedFileURL, paths: paths)
        }.value
    }

    func relinkRoot(_ preview: LibraryRelink) async throws {
        let verified = try await previewRelink(preview.destination)
        guard !isScanning, !isScanningVideos, !DeviceManager.shared.busy, libraryRoot == preview.source,
              relinkPaths == preview.paths, verified.paths == preview.paths, verified.missing == preview.missing else {
            throw SyncError("The library changed. Preview the relink again.")
        }
        guard preview.matched > 0 || preview.paths.isEmpty else {
            throw SyncError("Choose a folder containing some of the library’s original relative paths.")
        }
        let missing = Set(preview.missing)
        for track in tracks where missing.contains(track.id) { missingRelinkTracks[track.id] = track }
        missingRelinkPaths = missingRelinkPaths.filter { $0.hasPrefix("/") }.union(missing)
        VideoWatchHistory.shared.relink(from: preview.source, to: preview.destination, paths: preview.paths)
        if preview.source != preview.destination && !legacyVideoRoots.contains(preview.source) {
            legacyVideoRoots.insert(preview.source, at: 0)
        }
        libraryFolders = libraryFolders.map { $0 == preview.source ? preview.destination : $0 }
        libraryRoot = preview.destination
        scan()
        saveNowBlocking()
    }

    func inboxMatchIndex() -> [[String]: [Track]] {
        Dictionary(grouping: tracks) { InboxEntry.matchKey($0.title, $0.album, $0.displayAlbumArtist) }
    }

    func importMatches(_ entry: InboxEntry, among candidates: [Track]? = nil) -> [Track] {
        let candidates = candidates ?? tracks.filter {
            InboxEntry.matchKey($0.title, $0.album, $0.displayAlbumArtist) == entry.matchKey
        }
        return candidates.filter {
            (entry.tags.year == 0 || $0.year == 0 || $0.year == entry.tags.year) &&
            (entry.tags.track == 0 || $0.trackNumber == 0 || $0.trackNumber == entry.tags.track) &&
            (entry.tags.disc == 0 || $0.discNumber == 0 || $0.discNumber == entry.tags.disc)
        }
    }

    func isImportUpgrade(_ entry: InboxEntry, over track: Track) -> Bool {
        guard track.isMusic else { return false }
        return entry.tags.lossless && !track.lossless ||
            entry.tags.codec == track.codec && !track.lossless && entry.tags.bitrate > track.bitrate
    }

    func importInboxEntry(_ entry: InboxEntry, replace: Bool) throws {
        guard let destinationRoot = downloadFolder, !isScanning, !isScanningVideos, !DeviceManager.shared.busy else {
            throw SyncError("The library is busy or unavailable.")
        }
        let fm = FileManager.default
        let matches = importMatches(entry)
        let old = replace && matches.count == 1 && isImportUpgrade(entry, over: matches[0]) ? matches[0] : nil
        guard matches.isEmpty || old != nil else { throw SyncError("This track already exists in the library.") }
        let root = old.flatMap { url(for: $0) }.flatMap { folder(containing: $0) } ?? destinationRoot
        let incoming = entry.url.resolvingSymlinksInPath()
        guard !libraryFolders.contains(where: { LibraryFolders.contains($0, incoming) }) else {
            throw SyncError("This file is already inside the library folder.")
        }
        guard let tags = TagReader.read(url: incoming) else { throw SyncError("The source is no longer readable.") }
        let ext = incoming.pathExtension.lowercased()
        let prior = old.flatMap { url(for: $0) }
        if let old {
            guard let prior, try prior.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                  prior.resolvingSymlinksInPath().path == prior.standardizedFileURL.path ||
                  prior.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  isImportUpgrade(InboxEntry(url: incoming, tags: tags), over: old),
                  importMatches(InboxEntry(url: incoming, tags: tags)).map(\.id) == [old.id] else {
                throw SyncError("The source or library copy changed. Review the import again.")
            }
        }
        let artist = tags.albumArtist.isEmpty ? tags.artist : tags.albumArtist
        let album = tags.album.isEmpty ? "Unknown Album" : tags.album
        let folder = prior?.deletingLastPathComponent() ?? root.appendingLibraryPath("Music")
            .appendingPathComponent(PathRules.sanitize(artist.isEmpty ? "Unknown Artist" : artist))
            .appendingPathComponent(PathRules.sanitize(tags.year > 0 ? "\(tags.year) - \(album)" : album))
        let number = tags.track > 0 ? String(format: "%02d. ", tags.track) : ""
        let disc = tags.disc > 1 ? "\(tags.disc)-" : ""
        let filename = PathRules.sanitize(disc + number + (tags.title.isEmpty ? incoming.deletingPathExtension().lastPathComponent : tags.title))
        let destination = (prior?.deletingPathExtension() ?? folder.appendingPathComponent(filename)).appendingPathExtension(ext)
        let folderPath = folder.resolvingSymlinksInPath().path
        guard folderPath.hasPrefix(root.resolvingSymlinksInPath().path + "/") || folderPath == root.resolvingSymlinksInPath().path,
              !fm.fileExists(atPath: destination.path) || destination.path == prior?.path else {
            throw SyncError("An existing file or folder prevents this import.")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".import-\(UUID())").appendingPathExtension(ext)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: incoming, to: staging)
        guard let newID = mediaID(for: destination) else {
            throw SyncError("Could not locate the destination inside the library.")
        }
        if let prior, destination.path == prior.path {
            _ = try fm.replaceItemAt(prior, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
            if let prior {
                do { try fm.trashItem(at: prior, resultingItemURL: nil) }
                catch { try? fm.removeItem(at: destination); throw error }
            }
        }
        let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if var old, let i = index[old.id] {
            ArtworkLoader.shared.forget(old)
            let oldID = old.id
            old.id = newID
            old.update(from: tags, size: size, modified: date)
            tracks[i] = old
            if unchecked.remove(oldID) != nil { unchecked.insert(newID) }
            if oldID != newID {
                replacedTrackPaths = replacedTrackPaths.mapValues { $0 == oldID ? newID : $0 }
                replacedTrackPaths[oldID] = newID
            }
            playlists = playlists.map { playlist in
                var updated = playlist
                updated.trackIDs = playlist.trackIDs.map { $0 == oldID ? newID : $0 }
                return updated
            }
        } else {
            tracks.append(Track(id: newID, size: size, modified: date, info: tags, dateAdded: Date().timeIntervalSince1970))
        }
        rebuildIndex()
        saveNowBlocking()
    }

    /// Re-roots the library without losing anything when the new folder contains the old one
    /// (…/Media/Music → …/Media): song IDs gain the subfolder prefix, so play counts, checkboxes
    /// and playlists carry over, and the scan reuses all cached tags. Devices keep their files:
    /// songs under a top-level Music/ folder map to the same device paths as before.
    private func migrate(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        guard oldPath != newPath, oldPath.hasPrefix(newPath + "/") else {
            if oldPath != newPath { videos = []; uncheckedVideos = []; episodeSources = [:] }
            return
        }
        let prefix = String(oldPath.dropFirst(newPath.count + 1)) + "/"
        episodeSources = Dictionary(uniqueKeysWithValues: episodeSources.map { (prefix + $0.key, $0.value) })
        replacedTrackPaths = Dictionary(uniqueKeysWithValues: replacedTrackPaths.map { (prefix + $0.key, prefix + $0.value) })
        tracks = tracks.map { t in
            var c = t
            c.id = prefix + t.id
            return c
        }
        unchecked = Set(unchecked.map { prefix + $0 })
        playlists = playlists.map { pl in
            var c = pl
            c.trackIDs = pl.trackIDs.map { prefix + $0 }
            c.importedFrom = pl.importedFrom.map { prefix + $0 }
            return c
        }
        videos = []
        uncheckedVideos = []
        rebuildIndex()
    }

    func scan() {
        guard let root = libraryRoot, !isScanning else { return }
        isScanning = true
        scanStatus = "Scanning library…"
        let existing = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            .merging(missingRelinkTracks) { current, _ in current }
        let aliases = replacedTrackPaths
        let folders = libraryFolders
        let store = self
        Task.detached(priority: .userInitiated) {
            let result = LibraryFolders.scan(folders, anchor: root, existing: existing, aliases: aliases) { done, total in
                Task { @MainActor in
                    store.scanStatus = total == 0 ? "Scanning library…" : "Reading tags: \(done.formatted()) of \(total.formatted())"
                }
            }
            await MainActor.run {
                store.apply(result.scan, unavailable: result.unavailable)
                store.missingRelinkPaths.formUnion(result.unavailable)
                if !folders.allSatisfy(LibraryFolders.available) {
                    store.scanStatus += " · Some folders are unavailable"
                }
                store.scheduleSave()
            }
        }
        scanVideos()
    }

    private func apply(_ result: ScanResult, unavailable: Set<String> = []) {
        tracks = result.tracks
        rebuildIndex()
        let found = Set(index.keys)
        missingRelinkPaths.subtract(found.subtracting(unavailable))
        missingRelinkPaths.formUnion(unavailable)
        missingRelinkTracks = missingRelinkTracks.filter { !found.contains($0.key) }
        unchecked.formIntersection(found.union(missingRelinkPaths))

        // Mirror playlists found in the library folder.
        var updated = playlists.filter { pl in
            guard let src = pl.importedFrom else { return true }
            return result.playlists.contains { $0.relativePath == src } || pl.trackIDs.contains(where: missingRelinkPaths.contains)
        }
        for scanned in result.playlists {
            if let i = updated.firstIndex(where: { $0.importedFrom == scanned.relativePath }) {
                if missingRelinkPaths.isEmpty || !updated[i].trackIDs.contains(where: missingRelinkPaths.contains) {
                    updated[i].trackIDs = scanned.trackIDs
                }
            } else {
                updated.append(Playlist(id: UUID(), name: scanned.name, trackIDs: scanned.trackIDs,
                                        importedFrom: scanned.relativePath))
            }
        }
        playlists = updated

        isScanning = false
        var parts: [String] = []
        if result.added > 0 { parts.append("\(result.added.formatted()) added") }
        if result.updated > 0 { parts.append("\(result.updated.formatted()) updated") }
        if result.removed > 0 { parts.append("\(result.removed.formatted()) removed") }
        scanStatus = parts.isEmpty ? "" : "Library updated: " + parts.joined(separator: ", ")
        scheduleSave()
    }

    // MARK: Podcast downloads

    func trashPodcastEpisodes(_ ids: Set<String>) -> (removed: Set<String>, failures: [String]) {
        guard !isScanning, libraryRoot != nil else {
            return ([], ["Try again when the library folder is available and scanning has finished."])
        }
        let files = FileManager.default
        var removed = Set<String>()
        var failures: [String] = []
        for id in ids.sorted() {
            guard let episode = track(id), episode.podcastShow != nil, let url = url(for: episode) else { continue }
            do {
                try files.trashItem(at: url, resultingItemURL: nil)
                removed.insert(id)
            } catch {
                failures.append("\(episode.title): \(error.localizedDescription)")
                continue
            }
            for sidecar in [PodcastMetadata.sidecar(for: url), url.appendingPathExtension("cover")]
                where files.fileExists(atPath: sidecar.path) {
                do {
                    try files.trashItem(at: sidecar, resultingItemURL: nil)
                } catch {
                    failures.append("\(sidecar.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if !removed.isEmpty {
            tracks.removeAll { removed.contains($0.id) }
            rebuildIndex()
            unchecked.subtract(removed)
            playlists = playlists.map { playlist in
                guard !playlist.isImported else { return playlist }
                var updated = playlist
                updated.trackIDs.removeAll { removed.contains($0) }
                return updated
            }
            scheduleSave()
        }
        return (removed, failures)
    }

    // MARK: Checkboxes

    func setChecked(_ ids: [String], _ checked: Bool) {
        var set = unchecked
        if checked { set.subtract(ids) } else { set.formUnion(ids) }
        unchecked = set
        scheduleSave()
    }

    func toggleChecked(_ id: String) {
        setChecked([id], unchecked.contains(id))
    }

    // MARK: Plays

    func importDevicePlays(_ plays: [DevicePlayCount], deviceID: String) throws -> (count: Int, scrobbles: [LastFM.Scrobble]) {
        func key(_ title: String, _ artist: String, _ album: String) -> [String] {
            [title, artist, album].map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        }
        var candidates: [[String]: Set<Int>] = [:]
        for (i, track) in tracks.enumerated() where track.isMusic {
            for artist in [track.artist, track.albumArtist] where !artist.isEmpty {
                candidates[key(track.title, artist, track.album), default: []].insert(i)
            }
        }
        var updated = tracks
        var totals = devicePlayTotals
        var count = 0
        var scrobbles: [LastFM.Scrobble] = []
        let now = Int(Date().timeIntervalSince1970)
        for play in plays where play.kind == .music && play.total > 0 {
            let id = deviceID + ":" + play.id.base64EncodedString()
            let previous = totals[id]
            let delta = previous.map { max(0, play.total - $0) } ?? play.recent
            guard let matches = candidates[key(play.title, play.artist, play.album)], matches.count == 1,
                  let index = matches.first else { continue }
            totals[id] = max(previous ?? 0, play.total)
            guard delta > 0 else { continue }
            let time = play.lastPlayed > 0 && play.lastPlayed <= now ? play.lastPlayed : 0
            updated[index].playCount += delta
            updated[index].lastPlayed = max(updated[index].lastPlayed, Double(time))
            count += delta
            scrobbles += LastFM.deviceEntries(for: updated[index], count: delta, latestEvent: play.latestEvent,
                                              duration: play.duration, now: now)
        }
        guard totals != devicePlayTotals else { return (0, []) }
        var saved = makeSaved()
        saved.tracks = updated
        saved.devicePlayTotals = totals
        let url = libraryFile
        try saveQueue.sync { try JSONEncoder().encode(saved).write(to: url, options: .atomic) }
        devicePlayTotals = totals
        if count > 0 { tracks = updated }
        return (count, scrobbles)
    }

    func recordPlay(_ id: String, at date: Date = Date()) {
        guard let i = index[id] else { return }
        tracks[i].playCount += 1
        tracks[i].lastPlayed = date.timeIntervalSince1970
        scheduleSave()
    }

    /// Bulk play-count import (from a device's .scrobbler.log).
    func addPlays(_ plays: [String: (count: Int, last: Double)]) {
        guard !plays.isEmpty else { return }
        var copy = tracks
        for (id, p) in plays {
            guard let i = index[id] else { continue }
            copy[i].playCount += p.count
            copy[i].lastPlayed = max(copy[i].lastPlayed, p.last)
        }
        tracks = copy
        scheduleSave()
    }

    // MARK: Smart playlists (same rules as the ones synced to the device)

    static let smartPlaylistNames = ["Recently Added", "Recently Played", "Top 25 Most Played", "My Top Rated"]

    func builtInSmartList(named name: String) -> SmartPlaylist? {
        guard let index = Self.smartPlaylistNames.firstIndex(of: name) else { return nil }
        let ids = [
            UUID(uuidString: "3ABC23E6-DAB7-4270-A637-63558FE29159")!,
            UUID(uuidString: "84727F11-3C16-4DD9-93E4-B1093277685D")!,
            UUID(uuidString: "CE383C15-2DE9-4F33-AD97-F38446FB4CE7")!,
            UUID(uuidString: "507C8D45-AF6C-4D0C-9D62-3517568E0E91")!
        ]
        let id = ids[index]
        if let saved = smartList(id) { return saved }
        var list = SmartPlaylist()
        list.id = id
        list.name = name
        list.syncToIPod = false
        list.limitEnabled = index != 3
        list.selectedBy = [.mostRecentlyAdded, .mostRecentlyPlayed, .mostOftenPlayed, .highestRating][index]
        if index == 3 { list.sortWithoutLimit = true }
        list.rules = []
        if index > 0 {
            var rule = SmartRule()
            rule.field = [.dateAdded, .lastPlayed, .playCount, .rating][index]
            rule.op = index == 1 ? .isSet : .greater
            rule.number = index == 3 ? 3 : 0
            list.rules = [rule]
        }
        return list
    }

    func smartPlaylist(named name: String) -> Playlist? {
        builtInSmartList(named: name).map(asPlaylist)
    }

    // MARK: Ratings, play counts, edited files

    func saveListening(_ id: String, position: Double, finished: Bool = false) {
        guard let i = index[id], !tracks[i].isMusic, position.isFinite else { return }
        let position = finished ? 0 : max(0, min(position, tracks[i].duration))
        guard tracks[i].resumePosition != position || (finished && tracks[i].finishedListening != true) ||
              (!finished && position > 0 && tracks[i].finishedListening == true) else { return }
        var updated = tracks
        updated[i].resumePosition = position
        if finished { updated[i].finishedListening = true }
        else if position > 0 { updated[i].finishedListening = false }
        tracks = updated
        scheduleSave()
    }

    func listeningChanges(_ plays: [DevicePlayCount], includeMatching: Bool = false) -> [ListeningChange] {
        func key(_ title: String, _ album: String) -> [String] {
            [title, album].map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        }
        let audio = Dictionary(grouping: tracks) { track in
            key(track.title, track.podcastShow ?? track.audiobookTitle ?? track.album)
        }
        let spoken = tracks.filter { !$0.isMusic }
        var byPath: [String: [Track]] = [:]
        var byEnclosure: [String: [Track]] = [:]
        var byRSSTags: [[String]: [Track]] = [:]
        for track in spoken {
            guard let url = url(for: track) else { continue }
            let kind: ClassicMediaKind = track.podcastShow != nil ? .podcast : .audiobook
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date(timeIntervalSince1970: track.modified)
            let path = SyncEngine.transferPath(url, size: Int(track.size), date: date, kind: kind)
            byPath[path.lowercased(), default: []].append(track)
            if let show = track.podcastShow, let metadata = PodcastMetadata.load(for: url) {
                byEnclosure[metadata.enclosure, default: []].append(track)
                if let title = metadata.title { byRSSTags[key(title, show), default: []].append(track) }
            }
        }
        var videoKeys: [String: [VideoItem]] = [:]
        for video in videos {
            let url = url(forVideo: video)
            let title = url.flatMap { videoMetadata(for: $0)?.title } ?? video.title
            let keys = Set([video.title, title].map {
                Song.videoSyncKey(tv: video.kind == .tv, show: video.show, season: video.season, episode: video.episode, title: $0)
            })
            for key in keys { videoKeys[key, default: []].append(video) }
        }
        let corrections = episodeCorrections()
        let videoByURL = Dictionary(uniqueKeysWithValues: videos.compactMap { video in url(forVideo: video).map { ($0, video) } })
        let changes = plays.compactMap { play -> ListeningChange? in
            let position = Double(play.bookmarkMilliseconds) / 1000
            let corrected = play.kind == .tvShow ? corrections.only { correction in
                correction.transfers.contains { $0.matches(path: play.filePath, size: play.fileSize) }
            }.flatMap { videoByURL[$0.target] } : nil
            let normal = play.videoSyncKey.flatMap { videoKeys[$0]?.only { _ in true } }
            if let video = corrected ?? normal, let url = url(forVideo: video) {
                let state = VideoWatchHistory.shared.state(at: url)
                guard includeMatching || abs(state.seconds - position) >= 0.5 || state.watched != play.played else { return nil }
                return ListeningChange(local: .video(video, url, state), play: play, position: position)
            }
            let matches = audio[key(play.title, play.album)]?.filter { track in
                let kind: ClassicMediaKind = track.podcastShow != nil ? .podcast : track.audiobookTitle != nil ? .audiobook : .music
                return kind == play.kind
            } ?? []
            let credited = matches.only { track in
                [track.artist, track.albumArtist].contains { $0.caseInsensitiveCompare(play.artist) == .orderedSame } ||
                    (!play.albumArtist.isEmpty && track.displayAlbumArtist.caseInsensitiveCompare(play.albumArtist) == .orderedSame)
            }
            let fallback = play.kind == .music ? [] : matches + (byRSSTags[key(play.title, play.album)] ?? [])
            let distinct = Dictionary(fallback.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let track = byPath[play.filePath]?.only { _ in true }
                ?? byEnclosure[play.enclosure]?.only { _ in true }
                ?? credited
                ?? distinct.values.only { _ in true }
            guard let track else { return nil }
            if play.kind == .music {
                guard track.rating != play.rating else { return nil }
            } else {
                guard includeMatching || abs((track.resumePosition ?? 0) - position) >= 0.5 ||
                      (track.finishedListening ?? false) != (play.played && position == 0) else { return nil }
            }
            return ListeningChange(local: .audio(track), play: play, position: position)
        }
        let grouped = Dictionary(grouping: changes, by: \.id)
        return changes.filter { grouped[$0.id]?.count == 1 }
    }

    func isCurrentListening(_ change: ListeningChange) -> Bool {
        switch change.local {
        case .audio(let audio):
            guard let current = track(audio.id) else { return false }
            return current.resumePosition == audio.resumePosition && current.finishedListening == audio.finishedListening
        case .video(let video, let source, let state):
            return source == url(forVideo: video) && VideoWatchHistory.shared.state(at: source) == state
        }
    }

    func applyListeningChanges(_ changes: [ListeningChange]) {
        var updated = tracks
        var imported = Set<String>()
        for change in changes {
            switch change.local {
            case .video(let video, let source, let state):
                guard source == url(forVideo: video), VideoWatchHistory.shared.state(at: source) == state else { continue }
                VideoWatchHistory.shared.update(source, seconds: change.position,
                                                duration: Double(change.play.duration), watched: change.play.played)
            case .audio(let track):
                guard let i = index[track.id] else { continue }
                if change.play.kind == .music {
                    guard updated[i].rating == track.rating else { continue }
                    updated[i].rating = change.play.rating
                } else {
                    guard updated[i].resumePosition == track.resumePosition,
                          updated[i].finishedListening == track.finishedListening else { continue }
                    updated[i].resumePosition = change.position
                    updated[i].finishedListening = change.play.played && change.position == 0
                    imported.insert(track.id)
                }
            }
        }
        if updated != tracks {
            tracks = updated
            saveNowBlocking()
        }
        if let id = PlayerEngine.shared.current?.id, imported.contains(id) {
            PlayerEngine.shared.refreshImportedListening(for: id)
        }
    }

    func setRating(_ ids: [String], _ stars: Int) {
        var copy = tracks
        for id in ids { if let i = index[id] { copy[i].rating = max(0, min(5, stars)) } }
        tracks = copy
        scheduleSave()
    }

    // MARK: User smart playlists

    func smartList(_ id: UUID) -> SmartPlaylist? { smartLists.first { $0.id == id } }

    func saveSmartList(_ list: SmartPlaylist) {
        if let i = smartLists.firstIndex(where: { $0.id == list.id }) { smartLists[i] = list } else { smartLists.append(list) }
        scheduleSave()
    }

    func deleteSmartList(_ id: UUID) {
        smartLists.removeAll { $0.id == id }
        scheduleSave()
    }

    func tracks(inSmart id: UUID) -> [Track] {
        guard let list = smartList(id) else { return [] }
        return list.evaluate(tracks, unchecked: unchecked).compactMap { track($0) }
    }

    /// User smart playlists as plain playlists (for syncing to a device).
    func smartListsAsPlaylists() -> [Playlist] {
        smartLists.filter { $0.syncToIPod != false }.map(asPlaylist)
    }

    var customSmartLists: [SmartPlaylist] {
        let builtInIDs = Set(Self.smartPlaylistNames.compactMap { builtInSmartList(named: $0)?.id })
        return smartLists.filter { !builtInIDs.contains($0.id) }
    }

    private func asPlaylist(_ list: SmartPlaylist) -> Playlist {
        Playlist(id: list.id, name: list.name, trackIDs: list.evaluate(tracks, unchecked: unchecked), importedFrom: nil)
    }

    /// Stores measured ReplayGain values (dB gains, linear peaks).
    func setLoudness(_ values: [String: AudioProcessor.Gains]) {
        guard !values.isEmpty else { return }
        var copy = tracks
        for (id, g) in values {
            guard let i = index[id] else { continue }
            copy[i].rgTrackGain = g.track
            copy[i].rgTrackPeak = g.trackPeak
            copy[i].rgAlbumGain = g.album
            copy[i].rgAlbumPeak = g.albumPeak
        }
        tracks = copy
        scheduleSave()
    }

    func resetPlayCount(_ ids: [String]) {
        var copy = tracks
        for id in ids { if let i = index[id] { copy[i].playCount = 0; copy[i].lastPlayed = 0 } }
        tracks = copy
        scheduleSave()
    }

    /// Re-reads tags for specific files (after Get Info wrote them), keeping play history.
    func refresh(_ ids: [String]) async {
        guard let root = libraryRoot else { return }
        let fresh: [(String, TagInfo, Int64, Double)] = await Task.detached(priority: .userInitiated) {
            ids.compactMap { id -> (String, TagInfo, Int64, Double)? in
                let url = root.appendingLibraryPath(id)
                guard let info = TagReader.read(url: url),
                      let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (id, info, Int64(v.fileSize ?? 0), v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }.value
        var copy = tracks
        for (id, info, size, modified) in fresh {
            if let i = index[id] { copy[i].update(from: info, size: size, modified: modified) }
        }
        tracks = Scanner.sortCanonical(copy)
        rebuildIndex()
        scheduleSave()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String, trackIDs: [String] = []) -> UUID {
        let pl = Playlist(id: UUID(), name: uniqueName(name), trackIDs: trackIDs, importedFrom: nil)
        playlists.append(pl)
        scheduleSave()
        return pl.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        playlists[i].name = name
        scheduleSave()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    func add(_ ids: [String], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.append(contentsOf: ids)
        // Editing an imported playlist detaches it from its file so rescans don't undo the edit.
        playlists[i].importedFrom = nil
        scheduleSave()
    }

    func remove(positions: IndexSet, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for p in positions.reversed() where p < playlists[i].trackIDs.count {
            playlists[i].trackIDs.remove(at: p)
        }
        playlists[i].importedFrom = nil
        scheduleSave()
    }

    func remove(ids: Set<String>, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { ids.contains($0) }
        playlists[i].importedFrom = nil
        scheduleSave()
    }

    nonisolated static let playlistDragPrefix = "rbsync-playlist:"

    /// Inserts songs at a position in a playlist. Songs already in it are moved, not duplicated.
    func place(_ ids: [String], at index: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var seen = Set<String>()
        let moving = ids.filter { seen.insert($0).inserted }
        let movingSet = Set(moving)
        var target = index
        var rest: [String] = []
        for (k, id) in playlists[i].trackIDs.enumerated() {
            if movingSet.contains(id) {
                if k < index { target -= 1 }
            } else {
                rest.append(id)
            }
        }
        target = max(0, min(target, rest.count))
        rest.insert(contentsOf: moving, at: target)
        playlists[i].trackIDs = rest
        playlists[i].importedFrom = nil
        scheduleSave()
    }

    /// Moves a playlist in the sidebar to just before another one.
    func movePlaylist(_ id: UUID, before target: UUID) {
        guard id != target, let from = playlists.firstIndex(where: { $0.id == id }) else { return }
        let pl = playlists.remove(at: from)
        let to = playlists.firstIndex(where: { $0.id == target }) ?? playlists.count
        playlists.insert(pl, at: to)
        scheduleSave()
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(playlists.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
