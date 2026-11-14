import ClassicSync
import Foundation
import Combine
import CryptoKit

/// The library: tracks, checkboxes, playlists. Persisted as JSON in Application Support.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    /// Canonically sorted (album artist, album, disc, track).
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    /// Smart playlists made in the app (the four built-in ones are separate).
    @Published private(set) var smartLists: [SmartPlaylist] = []
    /// iTunes-style checkboxes. Most songs are checked, so only the exceptions are stored.
    @Published private(set) var unchecked: Set<String> = []
    @Published private(set) var libraryRoot: URL?
    @Published private(set) var isScanning = false
    @Published private(set) var scanStatus = ""
    /// Videos found in the media library (TV / Movies / …), synced in the layout Y2-Rockbox indexes.
    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var uncheckedVideos: Set<String> = []
    @Published private(set) var isScanningVideos = false
    @Published private(set) var videoMetadataRevision = 0

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

    private var libraryFile: URL { Self.supportFolder.appendingPathComponent("library.json") }

    private struct Saved: Codable {
        var root: String?
        var tracks: [Track]
        var playlists: [Playlist]
        var unchecked: [String]
        var videoRoot: String?
        var videos: [VideoItem]?
        var uncheckedVideos: [String]?
        var smartLists: [SmartPlaylist]?
        var devicePlayTotals: [String: Int]? = nil
        var replacedTrackPaths: [String: String]? = nil
    }

    // MARK: Load / save

    func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            migratePreviousLibrary()
            return
        }
        libraryRoot = saved.root.map { URL(fileURLWithPath: $0, isDirectory: true) }
        tracks = saved.tracks
        playlists = saved.playlists
        unchecked = Set(saved.unchecked)
        videos = saved.videos ?? []
        uncheckedVideos = Set(saved.uncheckedVideos ?? [])
        smartLists = saved.smartLists ?? []
        devicePlayTotals = saved.devicePlayTotals ?? [:]
        replacedTrackPaths = saved.replacedTrackPaths ?? [:]
        rebuildIndex()
    }

    private func migratePreviousLibrary() {
        let defaults = UserDefaults.standard
        guard let path = defaults.stringArray(forKey: "musicFolders")?.first else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        libraryRoot = root
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
        Saved(root: libraryRoot?.path, tracks: tracks, playlists: playlists, unchecked: Array(unchecked),
              videoRoot: nil, videos: videos, uncheckedVideos: Array(uncheckedVideos), smartLists: smartLists,
              devicePlayTotals: devicePlayTotals, replacedTrackPaths: replacedTrackPaths)
    }

    // MARK: Videos

    func scanVideos() {
        guard let root = libraryRoot, !isScanningVideos else { return }
        isScanningVideos = true
        let store = self
        Task.detached(priority: .userInitiated) {
            let found = VideoScanner.scan(root: root)
            await MainActor.run {
                store.videos = found
                let ids = Set(found.map(\.id))
                store.uncheckedVideos = store.uncheckedVideos.filter { ids.contains($0) }
                store.isScanningVideos = false
                store.scheduleSave()
            }
        }
    }

    func url(forVideo v: VideoItem) -> URL? { libraryRoot?.appendingPathComponent(v.id) }

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
        guard let data = try? Data(contentsOf: videoMetadataURL(for: url)) else { return nil }
        return try? PropertyListDecoder().decode(VideoMetadataEdit.self, from: data)
    }

    func saveVideoMetadata(_ metadata: VideoMetadataEdit, for url: URL) throws {
        try writeVideoMetadata(metadata, for: url)
        videoMetadataRevision += 1
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

    private func writeVideoMetadata(_ metadata: VideoMetadataEdit, for url: URL) throws {
        let destination = videoMetadataURL(for: url)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(metadata).write(to: destination, options: .atomic)
    }

    private func videoMetadataURL(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Self.supportFolder.appending(path: "Video Metadata", directoryHint: .isDirectory)
            .appending(path: key + ".plist")
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
        libraryRoot?.appendingPathComponent(track.id)
    }

    func url(forID id: String) -> URL? {
        libraryRoot?.appendingPathComponent(id)
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
        guard !isScanning else { return }
        if let old = libraryRoot { migrate(from: old, to: url) }
        libraryRoot = url
        scheduleSave()
        scan()
    }

    func relinkRoot(_ url: URL) throws {
        guard !isScanning, !isScanningVideos, !DeviceManager.shared.busy, libraryRoot != nil,
              try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SyncError("Finish the current operation and choose the moved library folder.")
        }
        let paths = tracks.map(\.id) + videos.map(\.id)
        guard paths.allSatisfy({ FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) else {
            throw SyncError("Choose the folder that contains all of the library’s existing relative paths.")
        }
        libraryRoot = url
        saveNowBlocking()
        scan()
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
        guard let root = libraryRoot, !isScanning, !isScanningVideos, !DeviceManager.shared.busy else {
            throw SyncError("The library is busy or unavailable.")
        }
        let fm = FileManager.default
        let matches = importMatches(entry)
        let old = replace && matches.count == 1 && isImportUpgrade(entry, over: matches[0]) ? matches[0] : nil
        guard matches.isEmpty || old != nil else { throw SyncError("This track already exists in the library.") }
        let incoming = entry.url.resolvingSymlinksInPath()
        guard !incoming.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
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
        let folder = prior?.deletingLastPathComponent() ?? root.appendingPathComponent("Music")
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
        guard let newID = Scanner.relativePath(of: destination, rootPath: root.standardizedFileURL.path) else {
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
            if oldPath != newPath { videos = []; uncheckedVideos = [] }
            return
        }
        let prefix = String(oldPath.dropFirst(newPath.count + 1)) + "/"
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
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            scanStatus = "Library folder is unavailable"
            return
        }
        isScanning = true
        scanStatus = "Scanning library…"
        let existing = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let aliases = replacedTrackPaths

        let store = self
        Task.detached(priority: .userInitiated) {
            let result = Scanner.scan(root: root, existing: existing, aliases: aliases) { done, total in
                Task { @MainActor in
                    store.scanStatus = total == 0 ? "Scanning library…" : "Reading tags: \(done.formatted()) of \(total.formatted())"
                }
            }
            await store.apply(result)
        }
        scanVideos()
    }

    private func apply(_ result: ScanResult) {
        tracks = result.tracks
        rebuildIndex()
        unchecked = unchecked.filter { index[$0] != nil }

        // Mirror playlists found in the library folder.
        var updated = playlists.filter { pl in
            guard let src = pl.importedFrom else { return true }
            return result.playlists.contains { $0.relativePath == src }
        }
        for scanned in result.playlists {
            if let i = updated.firstIndex(where: { $0.importedFrom == scanned.relativePath }) {
                updated[i].trackIDs = scanned.trackIDs
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
            if play.latestEvent > 0, play.latestEvent <= now, play.duration >= 30 {
                scrobbles.append(LastFM.entry(for: updated[index], at: Double(max(1, play.latestEvent - play.duration))))
            }
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

    func smartPlaylist(named name: String) -> Playlist? {
        let ordered: [Track]
        switch name {
        case "My Top Rated":
            ordered = tracks.filter { $0.rating >= 4 }
                .sorted { $0.rating != $1.rating ? $0.rating > $1.rating : $0.playCount > $1.playCount }
        case "Top 25 Most Played":
            ordered = Array(tracks.filter { $0.playCount > 0 }
                .sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.lastPlayed > $1.lastPlayed }
                .prefix(25))
        case "Recently Played":
            ordered = Array(tracks.filter { $0.lastPlayed > 0 }.sorted { $0.lastPlayed > $1.lastPlayed }.prefix(25))
        case "Recently Added":
            ordered = Array(tracks.sorted { $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : $0.id < $1.id }
                .prefix(25))
        default:
            return nil
        }
        return Playlist(id: UUID(), name: name, trackIDs: ordered.map(\.id), importedFrom: nil)
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

    func listeningChanges(_ plays: [DevicePlayCount]) -> [ListeningChange] {
        func key(_ title: String, _ album: String) -> [String] {
            [title, album].map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        }
        var byTags: [[String]: [Track]] = [:]
        var byEnclosure: [String: [Track]] = [:]
        for track in tracks {
            let show = track.podcastShow ?? track.audiobookTitle ?? track.album
            byTags[key(track.title, show), default: []].append(track)
            if track.podcastShow != nil, let url = url(for: track), let metadata = PodcastMetadata.load(for: url) {
                byEnclosure[metadata.enclosure, default: []].append(track)
            }
        }
        let changes = plays.compactMap { play -> ListeningChange? in
            let enclosure = byEnclosure[play.enclosure]?.only { _ in true }
            let tagged = byTags[key(play.title, play.album)]?.only { track in
                let kind: ClassicMediaKind = track.podcastShow != nil ? .podcast : track.audiobookTitle != nil ? .audiobook : .music
                return kind == play.kind &&
                    [track.artist, track.albumArtist].contains { $0.caseInsensitiveCompare(play.artist) == .orderedSame }
            }
            guard let track = (play.kind == .podcast ? enclosure : nil) ?? tagged else { return nil }
            let position = min(track.duration, Double(play.bookmarkMilliseconds) / 1000)
            if play.kind == .music {
                guard track.rating != play.rating else { return nil }
            } else {
                guard abs((track.resumePosition ?? 0) - position) >= 1 ||
                      (track.finishedListening ?? false) != play.played else { return nil }
            }
            return ListeningChange(track: track, play: play, position: position)
        }
        let grouped = Dictionary(grouping: changes, by: \.id)
        return changes.filter { grouped[$0.id]?.count == 1 }
    }

    func applyListeningChanges(_ changes: [ListeningChange]) {
        var updated = tracks
        for change in changes {
            guard let i = index[change.id] else { continue }
            if change.play.kind == .music {
                guard updated[i].rating == change.track.rating else { continue }
                updated[i].rating = change.play.rating
            } else {
                guard updated[i].resumePosition == change.track.resumePosition,
                      updated[i].finishedListening == change.track.finishedListening else { continue }
                updated[i].resumePosition = change.position
                updated[i].finishedListening = change.play.played
            }
        }
        tracks = updated
        saveNowBlocking()
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
        smartLists.map { Playlist(id: $0.id, name: $0.name, trackIDs: $0.evaluate(tracks, unchecked: unchecked), importedFrom: nil) }
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
                let url = root.appendingPathComponent(id)
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
