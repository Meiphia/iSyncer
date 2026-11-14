import CryptoKit
import Darwin
import Foundation

public struct ClassicDeviceItem: Identifiable, Sendable, Equatable {
    public let id: Int
    public let title: String
    public let artist: String
    public let album: String
    public let kind: ClassicMediaKind
    public let season: Int
    public let persistentID: Data
    public let syncKey: String
    public let fileExtension: String
}

public struct Device: Identifiable, Equatable, Sendable {
    public var id: URL { mount }
    public var settingsID: String { guid.isEmpty ? mount.path : guid.map { String(format: "%02x", $0) }.joined() }
    public let mount: URL
    public let name: String
    public let model: String
    public let generation: String
    public let firmware: String
    public let capacity: Int64
    public let available: Int64
    public let trackCount: Int
    public let mediaBytes: [ClassicMediaKind: Int64]
    public let contents: [ClassicDeviceItem]
    public let syncIssue: String?
    fileprivate let guid: Data

    public static func connected() -> [Device] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
        return volumes.compactMap { try? inspect($0) }.sorted { $0.name < $1.name }
    }

    public static func inspect(_ mount: URL) throws -> Device {
        let layout = try DeviceLayout(mount)
        let info = layout.info
        let model = info["ModelNumStr"] as? String ?? ""
        let family = (info["FamilyID"] as? NSNumber)?.intValue
        let product = info["ProductType"] as? String ?? ""
        let isClassic = family == 11 || product == "iPodClassic"
        guard isClassic else { throw SyncError("This volume is not identified as an iPod Classic.") }
        let generation: String
        switch String(model.uppercased().suffix(4)) {
        case "C293", "C297": generation = "7th generation"
        case "B562", "B565": generation = "Late 2008"
        case "B029", "B147", "B145", "B150": generation = "6th generation"
        default: generation = "Click-wheel"
        }

        let guid = decodeGUID(info["FireWireGUID"] as? String ?? "")
        let values = try mount.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                         .volumeNameKey, .volumeIsReadOnlyKey])
        var issue: String?
        var count = 0
        var mediaBytes: [ClassicMediaKind: Int64] = [:]
        var contents: [ClassicDeviceItem] = []
        do {
            let data = try Data(contentsOf: layout.database)
            let tracks = try Database(data).tracks
            count = tracks.count
            for track in tracks {
                let raw = track.mediaType
                let kind: ClassicMediaKind
                if raw & 4 != 0 { kind = .podcast }
                else if raw & 8 != 0 { kind = .audiobook }
                else if raw & 64 != 0 { kind = .tvShow }
                else if raw & 34 != 0 { kind = .movie }
                else if raw == 0 || raw & 1 != 0 { kind = .music }
                else { continue }
                mediaBytes[kind, default: 0] += Int64(track.size)
                contents.append(.init(id: track.id, title: track.fields[1] ?? "Untitled", artist: track.fields[4] ?? "",
                                      album: track.fields[3] ?? "", kind: kind, season: track.season,
                                      persistentID: track.persistentID, syncKey: track.videoSyncKey,
                                      fileExtension: (track.path as NSString).pathExtension))
            }
            _ = try Signing(database: data, guid: guid)
            if values.volumeIsReadOnly == true { issue = "macOS mounted this iPod read-only." }
            if FileManager.default.fileExists(atPath: layout.control.appending(path: "iTunes/iTunesCDB").path) {
                issue = "This iPod has a compressed iTunesCDB. Sync requires the regular iTunesDB."
            }
        } catch {
            issue = error.localizedDescription
        }
        return Device(mount: mount, name: mount.lastPathComponent.isEmpty ? "iPod Classic" : mount.lastPathComponent,
                      model: model, generation: generation, firmware: info["VisibleBuildID"] as? String ?? "Unknown",
                      capacity: Int64(values.volumeTotalCapacity ?? 0), available: Int64(values.volumeAvailableCapacity ?? 0),
                      trackCount: count, mediaBytes: mediaBytes, contents: contents, syncIssue: issue, guid: guid)
    }

    fileprivate static func decodeGUID(_ value: String) -> Data {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = Array(hex.hasPrefix("0x") ? hex.dropFirst(2) : hex[...])
        guard digits.count == 16 else { return Data() }
        let bytes = stride(from: 0, to: 16, by: 2).compactMap { index in
            UInt8(String(digits[index...index + 1]), radix: 16)
        }
        return bytes.count == 8 ? Data(bytes) : Data()
    }
}

private struct DeviceLayout {
    let mount: URL
    let control: URL
    let database: URL
    let info: [String: Any]

    init(_ mount: URL) throws {
        self.mount = mount
        control = mount.appending(path: "iPod_Control")
        database = control.appending(path: "iTunes/iTunesDB")
        let device = control.appending(path: "Device")
        let extended = device.appending(path: "SysInfoExtended")
        guard Self.safeDirectory(control), Self.safeDirectory(device),
              Self.safeDirectory(database.deletingLastPathComponent()) else {
            throw SyncError("This volume does not contain an iPod library.")
        }
        var fields: [String: Any] = [:]
        if let data = try? Data(contentsOf: extended),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            fields = plist
        }
        if let text = try? String(contentsOf: device.appending(path: "SysInfo"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if fields[key] == nil {
                    if key == "FamilyID", let family = Int(value) { fields[key] = family }
                    else { fields[key] = value }
                }
            }
        }
        if fields["VisibleBuildID"] == nil { fields["VisibleBuildID"] = fields["visibleBuildID"] }
        info = fields
    }

    static func safeDirectory(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return value.isDirectory == true && value.isSymbolicLink != true
    }

    static func safeFile(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return value.isRegularFile == true && value.isSymbolicLink != true
    }

    func trackURL(for path: String) -> URL? {
        let components = path.split(separator: ":").map(String.init)
        guard components.count == 4, components[0].caseInsensitiveCompare("iPod_Control") == .orderedSame,
              components[1].caseInsensitiveCompare("Music") == .orderedSame,
              components.allSatisfy({ !$0.contains("/") && $0 != "." && $0 != ".." }) else { return nil }
        let folder = control.appending(path: "Music").appending(path: components[2])
        guard Self.safeDirectory(folder), Self.safeDirectory(folder.deletingLastPathComponent()) else { return nil }
        return folder.appending(path: components[3])
    }
}

public struct SyncItem: Codable, Sendable {
    public enum Action: String, CaseIterable, Codable, Sendable {
        case add = "Add", replace = "Replace", metadata = "Update Metadata", remove = "Remove", skip = "Skip"
    }
    public let action: Action
    public let title: String
    public let detail: String
    public var sourceURL: URL? = nil
    public var metadataChanges: [SyncMetadataChange]? = nil
    public init(_ action: Action, _ title: String, _ detail: String = "") {
        self.action = action
        self.title = title
        self.detail = detail
    }
}

public struct SyncMetadataChange: Codable, Sendable {
    public let field: String
    public let before: String
    public let after: String
    public var beforeImage: Data? = nil
    public var afterImage: Data? = nil
}

public struct SyncPlan: Sendable {
    public let items: [SyncItem]
    public let videoExclusions: [String: String]
    public let playedPodcastSources: Set<URL>
    public let pending: [Song]
    public let alreadyOnDevice: Int
    public let bytes: Int64
    public let reclaimableBytes: Int64
    public var removedTrackCount: Int { removedTracks.count }
    public let available: Int64
    public var canFit: Bool { required <= available - fillReserve }
    public var playlistCount: Int { playlists.count }
    public var removedPlaylistCount: Int { removedPlaylists.count }
    public let removedDefaultPlaylistNames: [String]
    public var podcastUpdateCount: Int { podcastUpdates.count }
    public var videoReleaseDateUpdateCount: Int { videoReleaseDates.count }
    public var videoTitleUpdateCount: Int { videoTitles.count }
    public var videoDescriptionUpdateCount: Int { videoDescriptions.count }
    public let repairsPodcastIndex: Bool
    public var videoReplacementCount: Int { entries.filter { $0.replacesTrackID != nil }.count }
    public func isVideoReplacement(at index: Int) -> Bool {
        entries.indices.contains(index) && entries[index].replacesTrackID != nil
    }

    public func videoReplacements(inCompletedTransfers count: Int) -> Int {
        entries.prefix(max(0, count)).filter { $0.replacesTrackID != nil }.count
    }
    public var artworkCandidates: Int { artworkSongs.count }
    public var removedVideoArtworkCount: Int { removedVideoArtwork.count }
    public let retagCount: Int
    public var hasChanges: Bool {
        !entries.isEmpty || !playlists.isEmpty || !removedPlaylists.isEmpty || !artworkSongs.isEmpty ||
        retagCount > 0 || !podcastUpdates.isEmpty || !videoReleaseDates.isEmpty || !videoTitles.isEmpty ||
        !videoDescriptions.isEmpty || !removedVideoArtwork.isEmpty || !removedTracks.isEmpty || repairsPodcastIndex ||
        !listening.isEmpty
    }
    fileprivate let entries: [Database.Addition]
    fileprivate let device: Device
    fileprivate let signature: Data
    fileprivate let required: Int64
    fileprivate let playlists: [Database.PlaylistUpdate]
    fileprivate let removedPlaylists: Set<Data>
    fileprivate let removedTracks: Set<Int>
    fileprivate let podcastUpdates: [String: Song]
    fileprivate let videoReleaseDates: [String: Int]
    fileprivate let videoTitles: [String: String]
    fileprivate let videoDescriptions: [String: String]
    fileprivate let removedVideoArtwork: Set<String>
    fileprivate let artistOverrides: [String: String]
    fileprivate let artworkSongs: [String: Song]
    fileprivate let listening: [String: ClassicListeningState]
    fileprivate let fillReserve: Int64
    fileprivate let playLogSnapshot: Data?
    fileprivate let podcastPlaySnapshots: [URL: Data?]
}

public struct ClassicRestorePreview: Sendable {
    public let currentTracks: Int
    public let backupTracks: Int
    public let unlistedFiles: Int
    public let missingFiles: Int
    public let positionalPlayLogExists: Bool
    fileprivate let signature: Data
    fileprivate let sourceSignature: Data
    fileprivate let source: URL
    fileprivate let device: Device

    public var canRestore: Bool { missingFiles == 0 && !positionalPlayLogExists && signature != sourceSignature }
}

public enum SyncEngine {
    public static func previewRestore(_ source: URL, on device: Device) throws -> ClassicRestorePreview {
        let layout = try DeviceLayout(device.mount)
        let (current, live, _) = try load(device, layout: layout)
        guard DeviceLayout.safeFile(source) else { throw SyncError("The backup file is unavailable.") }
        let backup = try Data(contentsOf: source)
        _ = try Signing(database: backup, guid: device.guid)
        let snapshot = try Database(backup)
        let paths = Set(snapshot.tracks.map { $0.path.lowercased() })
        let livePaths = Set(live.tracks.map { $0.path.lowercased() })
        let missing = snapshot.tracks.filter { track in
            guard let url = layout.trackURL(for: track.path), DeviceLayout.safeFile(url) else { return true }
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) != track.size
        }.count
        let changedOrder = snapshot.tracks.map(\.persistentID) != live.tracks.map(\.persistentID)
        let playLog = layout.database.deletingLastPathComponent().appending(path: "Play Counts")
        return ClassicRestorePreview(currentTracks: live.tracks.count, backupTracks: snapshot.tracks.count,
                                     unlistedFiles: livePaths.subtracting(paths).count, missingFiles: missing,
                                     positionalPlayLogExists: changedOrder && FileManager.default.fileExists(atPath: playLog.path),
                                     signature: Data(SHA256.hash(data: current)), sourceSignature: Data(SHA256.hash(data: backup)),
                                     source: source, device: device)
    }

    public static func restore(_ preview: ClassicRestorePreview, backups: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let descriptor = open(backups.appending(path: ".sync.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SyncError("Could not open the sync lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SyncError("Another iSyncer transfer is running.") }
        let fresh = try previewRestore(preview.source, on: preview.device)
        guard fresh.canRestore, fresh.signature == preview.signature, fresh.sourceSignature == preview.sourceSignature else {
            throw SyncError("The iPod or backup changed. Review the restore again.")
        }
        let layout = try DeviceLayout(preview.device.mount)
        let current = try Data(contentsOf: layout.database)
        let backup = try Data(contentsOf: preview.source)
        guard Data(SHA256.hash(data: current)) == fresh.signature,
              Data(SHA256.hash(data: backup)) == fresh.sourceSignature else {
            throw SyncError("The iPod or backup changed before restore.")
        }
        let copy = backups.appending(path: "iTunesDB-\(preview.device.settingsID)-\(UUID().uuidString).backup")
        try current.write(to: copy, options: .atomic)
        try backup.write(to: layout.database, options: .atomic)
        guard try Data(contentsOf: layout.database) == backup else {
            throw SyncError("Could not verify the restored database. The pre-restore backup is available.")
        }
    }

    public static func recover(_ item: ClassicDeviceItem, from device: Device, to destination: URL) throws {
        let layout = try DeviceLayout(device.mount)
        let (_, database, _) = try load(device, layout: layout)
        guard let track = database.tracks.first(where: { $0.id == item.id && $0.persistentID == item.persistentID }),
              let source = layout.trackURL(for: track.path), DeviceLayout.safeFile(source) else {
            throw SyncError("The iPod file is unavailable.")
        }
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent().appending(path: ".recovery-\(UUID())")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        guard fm.contentsEqual(atPath: source.path, andPath: temporary.path) else {
            throw SyncError("The recovered file did not match the iPod copy.")
        }
        try fm.moveItem(at: temporary, to: destination)
    }

    public static func readPlays(on device: Device, includeVideo: Bool = false) throws -> [DevicePlayCount] {
        let layout = try DeviceLayout(device.mount)
        let (original, database, _) = try load(device, layout: layout)
        let url = layout.database.deletingLastPathComponent().appending(path: "Play Counts")
        let plistURL = url.deletingLastPathComponent().appending(path: "PlayCounts.plist")
        let counts = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let plist = counts == nil && FileManager.default.fileExists(atPath: plistURL.path) ? try Data(contentsOf: plistURL) : nil
        let plays = try database.devicePlays(counts, plist: plist, includeVideo: includeVideo)
        guard try Data(contentsOf: layout.database) == original else {
            throw SyncError("The iPod library changed while reading play counts. Try again.")
        }
        return plays
    }

    public static func preview(_ candidates: [Song], on device: Device, options: SyncOptions = SyncOptions()) throws -> SyncPlan {
        let layout = try DeviceLayout(device.mount)
        let (original, database, _) = try load(device, layout: layout)
        let playedOnlyShows = Set(options.podcastLimits.compactMap { $0.value.removePlayed ? $0.key.precomposedStringWithCanonicalMapping : nil })
        let readsListening = options.expectedWatchedTVKeys != nil || options.podcastLimits.values.contains(where: \.unplayed)
        let activePlayLog = layout.database.deletingLastPathComponent().appending(path: "Play Counts")
        let activePlayPlist = activePlayLog.deletingLastPathComponent().appending(path: "PlayCounts.plist")
        let playFiles = !readsListening ? [] : [activePlayLog, activePlayPlist].filter { FileManager.default.fileExists(atPath: $0.path) }
        let playSnapshots = try playFiles.map { try Data(contentsOf: $0) }
        let played = !readsListening ? [] : try database.devicePlays(
            playFiles.first == activePlayLog ? playSnapshots.first : nil,
            plist: playFiles.first == activePlayPlist ? playSnapshots.first : nil,
            includeVideo: options.expectedWatchedTVKeys != nil
        )
        if let expected = options.expectedWatchedTVKeys,
           Set(played.filter { $0.kind == .tvShow && $0.played }.compactMap(\.videoSyncKey)) != expected {
            throw SyncError("iPod watching history changed. Preview Sync again.")
        }
        let playedIDs = Set(played.filter { $0.kind == .podcast && $0.played }.map(\.id))
        let deviceEnclosures = Set(played.filter { $0.kind == .podcast && $0.played && !$0.enclosure.isEmpty }.map(\.enclosure))
        let deviceTitles = Dictionary(grouping: played.filter { $0.kind == .podcast && $0.enclosure.isEmpty }) {
            [$0.album, $0.title].map { $0.precomposedStringWithCanonicalMapping }
        }
        let podcastCandidates = candidates.filter { $0.classification == .podcast }
        let localTitles = Dictionary(grouping: podcastCandidates) {
            [$0.group, $0.title].map { $0.precomposedStringWithCanonicalMapping }
        }
        var playedSources = Set<URL>()
        var playedEnclosures = Set<String>()
        let eligible = candidates.filter { song in
            guard song.classification == .podcast, let policy = options.podcastLimits[song.group], policy.unplayed else { return true }
            let enclosure = song.podcastMetadata?.enclosure ?? ""
            let title = [song.group, song.title].map { $0.precomposedStringWithCanonicalMapping }
            let oldMatch = localTitles[title]?.count == 1 && deviceTitles[title]?.count == 1
                && deviceTitles[title]?.first?.played == true
            let onDevice = (!enclosure.isEmpty && deviceEnclosures.contains(enclosure)) || oldMatch
            let locally = options.playedPodcastURLs.contains(song.url)
            if onDevice { playedSources.insert(song.url) }
            if (onDevice || locally), !enclosure.isEmpty { playedEnclosures.insert(enclosure) }
            return policy.pinned.contains(song.url) || (!onDevice && !locally)
        }
        let knownPodcastEnclosures = Dictionary(grouping: database.tracks.filter {
            $0.mediaType == ClassicMediaKind.podcast.rawValue && !($0.fields[15] ?? "").isEmpty
        }, by: { $0.fields[15] ?? "" })
        let candidateEnclosures = Dictionary(grouping: podcastCandidates.filter {
            !($0.podcastMetadata?.enclosure ?? "").isEmpty
        }, by: { $0.podcastMetadata?.enclosure ?? "" })
        let limitedEpisodes = Dictionary(grouping: eligible.filter {
            $0.classification == .podcast && options.podcastLimits[$0.group] != nil
        }, by: \.group)
        var retained = Set<URL>()
        for (show, episodes) in limitedEpisodes {
            guard let policy = options.podcastLimits[show] else { continue }
            let newest = episodes.sorted {
                let first = $0.releaseDate ?? $0.modificationDate
                let second = $1.releaseDate ?? $1.modificationDate
                return first == second ? $0.url.path < $1.url.path : first > second
            }
            retained.formUnion(newest.prefix(policy.latest).map(\.id))
            retained.formUnion(policy.pinned)
        }
        var songs = eligible.filter { song in
            guard options.retrySources?.contains(song.originalSource ?? song.url) ?? true else { return false }
            return song.classification != .podcast || options.podcastLimits[song.group] == nil || retained.contains(song.id)
        }
        var known: [[String]: Database.Track] = [:]
        var paths: [String: Database.Track] = [:]
        for track in database.tracks {
            guard let url = layout.trackURL(for: track.path), DeviceLayout.safeFile(url) else { continue }
            paths[track.path.lowercased()] = track
            let key = Song.matchKey(title: track.fields[1] ?? "", artist: track.fields[4] ?? "",
                                    album: track.fields[3] ?? "", size: track.size,
                                    disc: track.disc, number: track.number)
            let mediaType = track.mediaType == 0 ? ClassicMediaKind.music.rawValue : track.mediaType
            let typedKey = key + matchDiscriminator(mediaType, season: track.season, episode: track.episode)
            if known[typedKey] == nil { known[typedKey] = track }
        }

        let occupied = Set(database.tracks.map { $0.path.lowercased() })
        let selectedMusicPaths = Set((songs + options.fillAlbums.flatMap { $0 }).filter { $0.classification == .music }.map {
            transferPath($0.url, size: $0.size, date: $0.modificationDate, kind: .music).lowercased()
        })
        func existingTrack(for song: Song, path: String) -> Database.Track? {
            if song.classification == .podcast, let enclosure = song.podcastMetadata?.enclosure,
               candidateEnclosures[enclosure]?.count == 1, let match = knownPodcastEnclosures[enclosure],
               match.count == 1, let track = match.first, paths[track.path.lowercased()] != nil {
                return track
            }
            let albumArtistKey = song.albumArtist.isEmpty ? nil : Song.matchKey(
                title: song.title, artist: song.albumArtist, album: song.album, size: song.size,
                disc: song.disc, number: song.number)
            let discriminator = matchDiscriminator(song.classification.rawValue, season: song.season ?? 0, episode: song.episode ?? 0)
            let normalizedMatch = options.useAlbumArtistForArtist ? albumArtistKey.flatMap { known[$0 + discriminator] } : nil
            let originalVideoMatch = song.videoMetadata?.originalTitle.flatMap { title in
                known[Song.matchKey(title: title, artist: song.artist, album: song.album, size: song.size,
                                    disc: song.disc, number: song.number) + discriminator]
            }
            let candidate = known[song.matchKey + discriminator] ?? normalizedMatch ?? originalVideoMatch
            let otherEdition = song.classification == .music && candidate.map {
                $0.path.lowercased() != path.lowercased() &&
                    (selectedMusicPaths.contains($0.path.lowercased()) ||
                     (options.matchMusicByPath.contains(song.id) && isManagedTransferPath($0.path)))
            } == true
            return paths[path.lowercased()] ?? (otherEdition ? nil : candidate)
        }
        var includesFillTransfers = false
        if !options.fillAlbums.isEmpty {
            func transferCost(_ song: Song) -> Int64 {
                let path = transferPath(song.url, size: song.size, date: song.modificationDate, kind: song.classification)
                return existingTrack(for: song, path: path) == nil ? Int64(song.size) + 16_384 : 0
            }
            let available = Int64(try device.mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0)
            let playlistReserve = options.playlists.reduce(Int64(0)) { $0 + 2048 + Int64($1.paths.count) * 240 }
            var remaining = available - options.fillReserve - Int64(original.count) - 1_048_576 - playlistReserve
                - songs.reduce(Int64(0)) { $0 + transferCost($1) }
            for album in options.fillAlbums {
                let cost = album.reduce(Int64(0)) { $0 + transferCost($1) }
                if cost == 0 || cost <= remaining {
                    songs += album
                    remaining -= cost
                    includesFillTransfers = includesFillTransfers || cost > 0
                }
            }
        }
        var planned: Set<String> = []
        var replacedTracks: Set<Int> = []
        var entries: [Database.Addition] = []
        var alreadyOnDevice = 0
        var matchedPaths: [URL: String] = [:]
        var artistOverrides: [String: String] = [:]
        var retagCount = 0
        var podcastUpdates: [String: Song] = [:]
        var videoReleaseDates: [String: Int] = [:]
        var videoTitles: [String: String] = [:]
        var videoDescriptions: [String: String] = [:]
        var removedVideoArtwork = Set<String>()
        var artworkSongs: [String: Song] = [:]
        var excludedItems: [SyncItem] = []
        let artworkDBExists = FileManager.default.fileExists(atPath: layout.control.appending(path: "Artwork/ArtworkDB").path)
        let artworkIndex = options.artwork && artworkDBExists &&
            songs.contains { $0.classification == .podcast || $0.hasVideoArtwork || $0.videoMetadata?.customArtwork == true }
            ? try ArtworkWriter(control: layout.control, reservedIDs: [], remainingBytes: 0) : nil
        for song in songs {
            if song.videoSyncKeys.contains(where: { options.excludedVideos[$0] != nil }) {
                excludedItems.append(SyncItem(.skip, song.title, "Excluded from sync for this iPod."))
                continue
            }
            let path = transferPath(song.url, size: song.size, date: song.modificationDate, kind: song.classification)
            if let existing = existingTrack(for: song, path: path) {
                let existingPath = existing.path.lowercased()
                matchedPaths[song.id] = existingPath
                if song.classification == .music, options.useAlbumArtistForArtist, !song.albumArtist.isEmpty,
                   existing.fields[4] != song.albumArtist {
                    if artistOverrides.updateValue(song.albumArtist, forKey: existingPath) == nil { retagCount += 1 }
                }
                let needsPodcastArtwork = song.classification == .podcast &&
                    artworkIndex?.artworkOwners[existing.artworkID] != existing.persistentID
                let isVideo = song.classification == .movie || song.classification == .tvShow
                let changedCover = options.artwork && song.videoMetadata?.customArtwork == true &&
                    song.videoMetadata?.artworkData.map { artworkIndex?.matches($0, artworkID: existing.artworkID) != true } == true
                if options.artwork, isVideo, song.videoMetadata?.customArtwork == true,
                   !song.hasVideoArtwork, existing.artworkID != 0 {
                    removedVideoArtwork.insert(existingPath)
                }
                if options.artwork, !isVideo || song.hasVideoArtwork,
                   existing.artworkID == 0 || !artworkDBExists || needsPodcastArtwork || changedCover,
                   isVideo || ArtworkWriter.sourceArtwork(for: song) != nil {
                    artworkSongs[existingPath] = song
                }
                if song.classification == .podcast {
                    let release = Database.releaseTimestamp(song.releaseDate)
                    if release.map({ $0 != existing.releaseTimestamp }) == true ||
                        !Database.changedPodcastFields(song, on: existing).isEmpty {
                        podcastUpdates[existingPath] = song
                    }
                } else if isVideo {
                    let release = Database.releaseTimestamp(song.releaseDate) ?? (song.videoMetadata?.resetReleaseDate == true ? 0 : nil)
                    if let release, release != existing.releaseTimestamp {
                        videoReleaseDates[existingPath] = release
                    }
                    if song.videoMetadata?.originalTitle != nil, existing.fields[1] != song.title {
                        videoTitles[existingPath] = song.title
                    }
                    if let description = Database.videoDescription(song), (existing.fields[14] ?? "") != description {
                        videoDescriptions[existingPath] = description
                    }
                }
                alreadyOnDevice += 1
                continue
            }
            guard !occupied.contains(path.lowercased()) else {
                throw SyncError("A previous transfer of \(song.title) is listed on the iPod, but its media file is missing.")
            }
            let lowerPath = path.lowercased()
            matchedPaths[song.id] = lowerPath
            if song.classification == .music, options.useAlbumArtistForArtist, !song.albumArtist.isEmpty { artistOverrides[lowerPath] = song.albumArtist }
            if options.artwork, (song.classification != .movie && song.classification != .tvShow) || song.hasVideoArtwork {
                artworkSongs[lowerPath] = song
            }
            if planned.insert(lowerPath).inserted {
                var replacesTrackID: Int?
                if let previous = song.previousVideoEncoding,
                   let values = try? previous.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   let size = values.fileSize, let date = values.contentModificationDate,
                   let old = paths[transferPath(previous, size: size, date: date, kind: song.classification).lowercased()],
                   old.mediaType == song.classification.rawValue, replacedTracks.insert(old.id).inserted {
                    replacesTrackID = old.id
                }
                entries.append(.init(song: song, path: path, replacesTrackID: replacesTrackID))
            }
        }
        let existingPlaylists = options.playlists.isEmpty && options.removedPlaylists.isEmpty
            ? [:] : try database.playlistUpdates()
        let playlists = options.playlists.filter(\.sync).compactMap { playlist -> Database.PlaylistUpdate? in
            let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let update = Database.PlaylistUpdate(id: playlist.deviceID, name: name,
                                                 paths: playlist.members(in: songs).compactMap { matchedPaths[$0.id] })
            return existingPlaylists[update.id] == update ? nil : update
        }
        let removed = options.removedPlaylists.union(options.playlists.filter { !$0.sync }.map(\.id))
        let defaults = options.removeDefaultPlaylists ? try database.defaultPlaylistNames(
            excluding: Set(options.protectedPlaylists.union(options.playlists.map(\.id)).map(LocalPlaylist.deviceID))
        ) : [:]
        let removedIDs = Set(removed.map(LocalPlaylist.deviceID)).intersection(existingPlaylists.keys).union(defaults.keys)
        let bytes = entries.reduce(Int64(0)) { $0 + Int64($1.song.size) }
        let available = Int64(try device.mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0)
        let playlistBytes = playlists.reduce(Int64(0)) { $0 + 2048 + Int64($1.paths.count) * 240 }
        let overhead = Int64(original.count) + Int64(entries.count) * 12_288 + 1_048_576 + playlistBytes
        let podcastIDs = Set(paths.values.filter { $0.mediaType & ClassicMediaKind.podcast.rawValue != 0 }.map(\.id))
        let repairsPodcastIndex = try songs.contains { $0.classification == .podcast }
            && database.needsPodcastIndexRepair(for: podcastIDs)
        var removedTracks = Set(database.tracks.filter {
            options.removedVideoIDs.contains($0.persistentID) &&
                ($0.mediaType & (ClassicMediaKind.tvShow.rawValue | 34) != 0)
        }.map(\.id))
        guard removedTracks.count == options.removedVideoIDs.count else {
            throw SyncError("The selected videos changed on the iPod. Refresh and select them again.")
        }
        let wanted = Set(matchedPaths.values).union(options.retainedTVKeys.isEmpty ? [] :
            database.tracks.filter { $0.mediaType == ClassicMediaKind.tvShow.rawValue && options.retainedTVKeys.contains($0.videoSyncKey) }
                .map { $0.path.lowercased() })
        let expiredTV = Set(database.tracks.filter {
            $0.mediaType == ClassicMediaKind.tvShow.rawValue && options.expiredTVKeys.contains($0.videoSyncKey) &&
                !wanted.contains($0.path.lowercased()) && isManagedTransferPath($0.path)
        }.map(\.id))
        removedTracks.formUnion(expiredTV)
        let limitedShows = Set(options.podcastLimits.compactMap { $0.value.removeOlder ? $0.key.precomposedStringWithCanonicalMapping : nil })
        for track in database.tracks {
            let music = track.mediaType == 0 || track.mediaType == ClassicMediaKind.music.rawValue
            let limitedPodcast = track.mediaType == ClassicMediaKind.podcast.rawValue &&
                (limitedShows.contains((track.fields[3] ?? "").precomposedStringWithCanonicalMapping) ||
                 (playedOnlyShows.contains((track.fields[3] ?? "").precomposedStringWithCanonicalMapping) &&
                  (playedIDs.contains(track.persistentID) || playedEnclosures.contains(track.fields[15] ?? ""))))
            guard (music && options.reconcileMusic) || limitedPodcast,
                  !wanted.contains(track.path.lowercased()), isManagedTransferPath(track.path) else { continue }
            removedTracks.insert(track.id)
        }
        let survivingPaths = Set(database.tracks.filter { !removedTracks.contains($0.id) }.map { $0.path.lowercased() })
        var countedPaths = Set<String>()
        let playLog = layout.database.deletingLastPathComponent().appending(path: "Play Counts")
        let snapshot = options.listening.isEmpty || !FileManager.default.fileExists(atPath: playLog.path)
            ? nil : try Data(contentsOf: playLog)
        let loggedListening = options.listening.isEmpty ? [] : try readPlays(on: device)
        let loggedByID = Dictionary(loggedListening.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listening = Dictionary(songs.compactMap { song -> (String, ClassicListeningState)? in
            guard song.classification == .podcast || song.classification == .audiobook,
                  let state = options.listening[song.id], let path = matchedPaths[song.id] else { return nil }
            if let track = paths[path], let live = loggedByID[track.persistentID],
               live.bookmarkMilliseconds == min(state.milliseconds, song.duration),
               live.played == (state.played || live.recent > 0) { return nil }
            return (path, state)
        }, uniquingKeysWith: { first, _ in first })
        let reclaimableBytes = database.tracks.reduce(Int64(0)) { bytes, track in
            let path = track.path.lowercased()
            guard removedTracks.contains(track.id), !survivingPaths.contains(path),
                  countedPaths.insert(path).inserted, let file = layout.trackURL(for: track.path),
                  DeviceLayout.safeFile(file),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return bytes }
            return bytes + Int64(size)
        }
        let byID = Dictionary(uniqueKeysWithValues: database.tracks.map { ($0.id, $0) })
        var items = entries.map { entry in
            let song = entry.song
            var item = SyncItem(entry.replacesTrackID == nil ? .add : .replace, song.title,
                                entry.replacesTrackID == nil ? "No matching media file on this iPod." : "Replace an older iPod video encode.")
            item.sourceURL = song.originalSource ?? song.url
            if let id = entry.replacesTrackID, let track = byID[id] {
                let date = Database.releaseTimestamp(song.releaseDate)
                let description = Database.videoDescription(song)
                item.metadataChanges = videoChanges(track, title: track.fields[1] == song.title ? nil : song.title,
                                                    date: track.releaseTimestamp == date ? nil : date,
                                                    description: track.fields[14] == description ? nil : description,
                                                    cover: song.hasVideoArtwork && track.artworkID == 0 ? song : nil,
                                                    clearsCover: false, artworkIndex: artworkIndex)
            }
            return item
        }
        let transferPaths = Set(entries.map { $0.path.lowercased() })
        for path in Set(artistOverrides.keys).union(podcastUpdates.keys).union(videoReleaseDates.keys)
            .union(videoTitles.keys).union(videoDescriptions.keys).union(removedVideoArtwork).union(artworkSongs.keys)
            .subtracting(transferPaths).sorted() {
            guard let track = paths[path] else { continue }
            let detail = [
                artistOverrides[path] == nil ? nil : "Artist",
                podcastUpdates[path] == nil ? nil : "Podcast details",
                videoReleaseDates[path] == nil ? nil : "Release date",
                videoTitles[path] == nil ? nil : "Title",
                videoDescriptions[path] == nil ? nil : "Description",
                artworkSongs[path] == nil ? nil : "Check artwork",
                removedVideoArtwork.contains(path) ? "Clear artwork" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            var item = SyncItem(.metadata, videoTitles[path] ?? track.fields[1] ?? "Untitled", detail)
            if track.mediaType & (64 | 34) != 0 {
                item.metadataChanges = videoChanges(track, title: videoTitles[path], date: videoReleaseDates[path],
                                                    description: videoDescriptions[path], cover: artworkSongs[path],
                                                    clearsCover: removedVideoArtwork.contains(path), artworkIndex: artworkIndex)
            }
            items.append(item)
        }
        items += playlists.map { SyncItem(.metadata, $0.name, "Playlist") }
        items += removedIDs.map { SyncItem(.remove, defaults[$0] ?? existingPlaylists[$0]?.name ?? "Playlist", "Playlist") }
        items += database.tracks.filter { removedTracks.contains($0.id) }.map {
            let played = playedIDs.contains($0.persistentID) || playedEnclosures.contains($0.fields[15] ?? "")
            let reason = expiredTV.contains($0.id) ? "Outside this show’s next unwatched episodes or pinned selection."
                : options.removedVideoIDs.contains($0.persistentID) ? "Selected for removal."
                : $0.mediaType == ClassicMediaKind.podcast.rawValue ? (played ? "Played episode excluded by this show’s retention rules." : "Outside this show’s latest episodes.")
                : "Outside this iPod’s music selection."
            return SyncItem(.remove, $0.fields[1] ?? "Untitled", reason)
        }
        items += listening.keys.sorted().compactMap { path in
            guard let track = paths[path], let next = listening[path], let current = loggedByID[track.persistentID] else { return nil }
            var item = SyncItem(.metadata, track.fields[1] ?? "Untitled", "Listening position and played status")
            item.metadataChanges = [
                SyncMetadataChange(field: "Position", before: Self.bookmarkTime(current.bookmarkMilliseconds),
                                   after: Self.bookmarkTime(next.milliseconds)),
                SyncMetadataChange(field: "Played", before: current.played ? "Yes" : "No", after: next.played ? "Yes" : "No")
            ].filter { $0.before != $0.after }
            return item
        }
        if repairsPodcastIndex { items.append(SyncItem(.metadata, "Podcasts", "Rebuild episode index")) }
        return SyncPlan(items: items + excludedItems, videoExclusions: options.videoExclusionsToSave, playedPodcastSources: playedSources,
                        pending: entries.map(\.song), alreadyOnDevice: alreadyOnDevice, bytes: bytes, reclaimableBytes: reclaimableBytes,
                        available: available, removedDefaultPlaylistNames: Set(defaults.values).sorted(),
                        repairsPodcastIndex: repairsPodcastIndex, retagCount: retagCount,
                        entries: entries, device: device,
                        signature: Data(SHA256.hash(data: original)), required: bytes + overhead,
                        playlists: playlists, removedPlaylists: removedIDs, removedTracks: removedTracks,
                        podcastUpdates: podcastUpdates, videoReleaseDates: videoReleaseDates,
                        videoTitles: videoTitles, videoDescriptions: videoDescriptions, removedVideoArtwork: removedVideoArtwork,
                        artistOverrides: artistOverrides, artworkSongs: artworkSongs, listening: listening,
                        fillReserve: includesFillTransfers ? options.fillReserve : 0, playLogSnapshot: snapshot,
                        podcastPlaySnapshots: !readsListening ? [:] : [
                            activePlayLog: playFiles.firstIndex(of: activePlayLog).map { playSnapshots[$0] },
                            activePlayPlist: playFiles.firstIndex(of: activePlayPlist).map { playSnapshots[$0] }
                        ])
    }

    private static func videoChanges(_ track: Database.Track, title: String?, date: Int?, description: String?,
                                     cover: Song?, clearsCover: Bool, artworkIndex: ArtworkWriter?) -> [SyncMetadataChange] {
        var changes: [SyncMetadataChange] = []
        if let title { changes.append(.init(field: "Title", before: track.fields[1] ?? "", after: title)) }
        if let date {
            func formatted(_ value: Int) -> String {
                guard value > 0 else { return "" }
                return String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(value - 2_082_844_800))).prefix(10))
            }
            changes.append(.init(field: "Release date", before: formatted(track.releaseTimestamp), after: formatted(date)))
        }
        if let description { changes.append(.init(field: "Description", before: track.fields[14] ?? "", after: description)) }
        if cover != nil || clearsCover {
            changes.append(.init(field: "Cover", before: track.artworkID == 0 ? "" : "Current artwork",
                                 after: clearsCover ? "" : "New artwork",
                                 beforeImage: artworkIndex?.previewImage(artworkID: track.artworkID),
                                 afterImage: cover?.videoMetadata?.artworkData.flatMap(ArtworkWriter.previewImage)))
        }
        return changes
    }

    private static func matchDiscriminator(_ mediaType: Int, season: Int, episode: Int) -> [String] {
        let kind = String(mediaType)
        return mediaType == ClassicMediaKind.tvShow.rawValue ? [kind, String(season), String(episode)] : [kind]
    }

    private static func transferPath(_ url: URL, size: Int, date: Date, kind: ClassicMediaKind) -> String {
        let suffix = kind == .music ? "" : "\0\(kind.rawValue)"
        let key = "\(url.path)\0\(size)\0\(date.timeIntervalSinceReferenceDate)\(suffix)"
        let hash = Array(SHA256.hash(data: Data(key.utf8)))
        let stem = "IS" + hash.prefix(6).map { String(format: "%02X", $0) }.joined()
        let bucket = String(format: "F%02d", Int(hash[6]) % 50)
        let ext = url.pathExtension.lowercased() == "aiff" ? "aif" : url.pathExtension.lowercased()
        return ":iPod_Control:Music:\(bucket):\(stem).\(ext)"
    }

    private static func isManagedTransferPath(_ path: String) -> Bool {
        path.range(of: #"^:iPod_Control:Music:F[0-4][0-9]:IS[0-9A-F]{12}\.[A-Z0-9]+$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func bookmarkTime(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    public static func apply(_ plan: SyncPlan, backups: URL, stop: SyncStop? = nil,
                             notice: @Sendable (String) -> Void = { _ in },
                             report: ([SyncItem]) -> Void = { _ in },
                             progress: @Sendable (Int, Int, String) -> Void) throws -> Int {
        guard plan.hasChanges else { return 0 }
        let fm = FileManager.default
        let layout = try DeviceLayout(plan.device.mount)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let lockURL = backups.appending(path: ".sync.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SyncError("Could not open the sync lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SyncError("Another iSyncer transfer is running.") }

        let (original, database, signing) = try load(plan.device, layout: layout)
        guard Data(SHA256.hash(data: original)) == plan.signature else {
            throw SyncError("The iPod library changed since the preview. Run Preview Sync again.")
        }
        for (url, snapshot) in plan.podcastPlaySnapshots {
            let live = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard live == snapshot else { throw SyncError("iPod listening history changed. Preview Sync again.") }
        }
        let available = try plan.device.mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard plan.required <= Int64(available) - plan.fillReserve else { throw SyncError("There is not enough space on the iPod.") }
        for entry in plan.entries { try checkSource(entry.song) }
        let backup = backups.appending(path: "iTunesDB-\(plan.device.settingsID)-\(UUID().uuidString).backup")
        try original.write(to: backup, options: [.atomic])
        var addedFiles: [URL] = []
        var copied: [Database.Addition] = []
        var committed = false
        defer {
            if !committed {
                for file in addedFiles { try? fm.removeItem(at: file) }
            }
        }
        let music = layout.control.appending(path: "Music")
        if !plan.entries.isEmpty { try makeSafeDirectory(music) }
        for (index, entry) in plan.entries.enumerated() {
            if stop?.isRequested == true { break }
            try Task.checkCancellation()
            progress(index, plan.entries.count, entry.song.title)
            let segments = entry.path.split(separator: ":").map(String.init)
            let bucket = music.appending(path: segments[2])
            try makeSafeDirectory(bucket)
            guard let destination = layout.trackURL(for: entry.path) else {
                throw SyncError("The iPod music folder is inaccessible.")
            }
            // A killed transfer can leave a complete file before the database commit.
            // Reuse it only after verifying it byte for byte against the local source.
            if fm.fileExists(atPath: destination.path) {
                guard DeviceLayout.safeFile(destination), fm.contentsEqual(atPath: entry.song.url.path, andPath: destination.path) else {
                    throw SyncError("A different file already exists at \(destination.lastPathComponent).")
                }
                copied.append(entry)
                continue
            }
            let temporary = bucket.appending(path: ".isyncer-\(UUID().uuidString).part")
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: entry.song.url, to: temporary)
            try checkSource(entry.song)
            try fm.moveItem(at: temporary, to: destination)
            addedFiles.append(destination)
            copied.append(entry)
        }

        let stopped = stop?.isRequested == true
        guard !copied.isEmpty || (!stopped && plan.hasChanges) else {
            report(plan.items.map { $0.action == .skip ? $0 : SyncItem(.skip, $0.title, "Sync stopped before saving.") })
            return 0
        }
        let removedTracks = stopped ? [] : plan.removedTracks
        let availablePaths = Set(database.tracks.compactMap { track -> String? in
            guard let url = layout.trackURL(for: track.path), DeviceLayout.safeFile(url) else { return nil }
            return track.path.lowercased()
        }).union(copied.map { $0.path.lowercased() })
        let playlists = plan.playlists.map {
            Database.PlaylistUpdate(id: $0.id, name: $0.name, paths: $0.paths.filter(availablePaths.contains))
        }
        let writer: ArtworkWriter?
        if !plan.artworkSongs.isEmpty, !stopped {
            let free = try plan.device.mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            let reserve = plan.required - plan.bytes + plan.fillReserve + Int64(plan.artworkCandidates) * 1024
            writer = try ArtworkWriter(control: layout.control, reservedIDs: Set(database.tracks.map(\.artworkID)),
                                       remainingBytes: Int64(free) - reserve)
        } else {
            writer = nil
        }
        var checkedArtwork = 0
        var artworkSkips: [SyncItem] = []
        if writer != nil { progress(0, plan.artworkCandidates, "Preparing artwork…") }
        var updated = try database.adding(copied, playlists: playlists, removed: plan.removedPlaylists,
                                         removedTracks: removedTracks,
                                         artistOverrides: plan.artistOverrides, podcastUpdates: plan.podcastUpdates,
                                         videoReleaseDates: plan.videoReleaseDates, videoTitles: plan.videoTitles,
                                         videoDescriptions: plan.videoDescriptions,
                                         removedVideoArtwork: plan.removedVideoArtwork,
                                         listening: stopped ? [:] : plan.listening,
                                         rebuildPodcastIndex: plan.repairsPodcastIndex) { track in
            guard let writer, let song = plan.artworkSongs[track.path.lowercased()],
                  stop?.isRequested != true else { return nil }
            checkedArtwork += 1
            if checkedArtwork % 25 == 0 {
                progress(checkedArtwork, plan.artworkCandidates, "Preparing artwork…")
            }
            let link = try writer.add(song: song, persistentID: track.persistentID)
            if link == nil, ArtworkWriter.sourceArtwork(for: song) != nil {
                var item = SyncItem(.skip, song.title, "Artwork could not be written or did not fit.")
                item.sourceURL = song.originalSource ?? song.url
                artworkSkips.append(item)
            }
            return link
        }
        let artworkWarning = "Some covers were skipped because the iPod is low on free space."
        let plannedSkips = plan.items.filter { $0.action == .skip }
        guard updated != original || (!stopped && !plan.listening.isEmpty) else {
            if writer?.skippedForSpace == true { notice(artworkWarning) }
            report(artworkSkips.isEmpty ? plan.items.map { $0.action == .skip ? $0 : SyncItem(.skip, $0.title, "No change was written.") }
                   : artworkSkips + plannedSkips)
            return copied.count
        }
        try signing.sign(&updated)
        let verification = try Database(updated)
        _ = try Signing(database: updated, guid: plan.device.guid)
        let replacements = Set(copied.compactMap(\.replacesTrackID))
        let verifiedPaths = Dictionary(verification.tracks.map { ($0.path.lowercased(), $0) },
                                       uniquingKeysWith: { first, _ in first })
        guard verification.tracks.count == database.tracks.count + copied.count - replacements.count - removedTracks.count,
              !verification.tracks.contains(where: { removedTracks.contains($0.id) }),
              copied.allSatisfy({ entry in
                  guard let track = verifiedPaths[entry.path.lowercased()], track.size == entry.song.size,
                        let url = layout.trackURL(for: entry.path), DeviceLayout.safeFile(url),
                        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == entry.song.size else { return false }
                  return entry.replacesTrackID.map { track.id == $0 } ?? true
              }) else {
            throw SyncError("The updated database did not pass validation.")
        }
        progress(1, 1, "Saving iTunesDB…")
        try Task.checkCancellation()
        let (live, _, _) = try load(plan.device, layout: layout)
        guard live == original else {
            throw SyncError("The iPod library changed during transfer. Run Preview Sync again.")
        }
        for (url, snapshot) in plan.podcastPlaySnapshots {
            let live = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard live == snapshot else { throw SyncError("iPod listening history changed during sync. Try again.") }
        }
        let playCounts = layout.database.deletingLastPathComponent().appending(path: "Play Counts")
        let listening = stopped ? [:] : plan.listening
        if !listening.isEmpty {
            let exists = fm.fileExists(atPath: playCounts.path)
            let liveCounts = exists ? try Data(contentsOf: playCounts) : nil
            guard liveCounts == plan.playLogSnapshot else {
                throw SyncError("iPod listening activity changed since the preview. Run Preview Sync again.")
            }
            if !exists, fm.fileExists(atPath: playCounts.deletingLastPathComponent().appending(path: "PlayCounts.plist").path) {
                throw SyncError("This iPod uses a property-list play log. Turn off sending Mac progress to sync other changes.")
            }
        }
        var stagedCounts: (original: URL, filtered: URL)?
        defer {
            if let stagedCounts {
                if !committed { try? fm.moveItem(at: stagedCounts.original, to: playCounts) }
                try? fm.removeItem(at: stagedCounts.filtered)
            }
        }
        if (!removedTracks.isEmpty || !listening.isEmpty), fm.fileExists(atPath: playCounts.path) {
            guard DeviceLayout.safeFile(playCounts) else { throw SyncError("Invalid iPod Play Counts file.") }
            let counts = try Data(contentsOf: playCounts)
            let filtered = try database.playCounts(counts, removing: removedTracks, listening: listening)
            if filtered != counts {
                let folder = playCounts.deletingLastPathComponent()
                let token = UUID().uuidString
                let originalCounts = folder.appending(path: ".isyncer-plays-\(token).backup")
                let filteredCounts = folder.appending(path: ".isyncer-plays-\(token).part")
                try counts.write(to: backup.deletingPathExtension().appendingPathExtension("PlayCounts.backup"), options: [.atomic])
                do {
                    try filtered.write(to: filteredCounts, options: [.atomic])
                    guard try Data(contentsOf: playCounts) == counts else {
                        throw SyncError("The iPod play counts changed during sync. Try again.")
                    }
                    // Keep the positional log out of the firmware's way while its track order changes.
                    try fm.moveItem(at: playCounts, to: originalCounts)
                    stagedCounts = (originalCounts, filteredCounts)
                } catch {
                    try? fm.removeItem(at: filteredCounts)
                    throw error
                }
            }
        }
        try writer?.install(backup: backup.deletingPathExtension().appendingPathExtension("ArtworkDB.backup"))
        try updated.write(to: layout.database, options: [.atomic])
        committed = true
        if (try? Data(contentsOf: layout.database)) != updated {
            notice("The sync was written, but the saved iPod database could not be verified.")
            report([SyncItem(.skip, "iPod database", "The saved database could not be verified. Reconnect before syncing again.")])
            return copied.count
        }
        let activePaths = Set(verification.tracks.map { $0.path.lowercased() })
        var cleanupIssues: [SyncItem] = []
        if let stagedCounts {
            do {
                try fm.moveItem(at: stagedCounts.filtered, to: playCounts)
                try? fm.removeItem(at: stagedCounts.original)
            } catch {
                cleanupIssues.append(SyncItem(.skip, "iPod Play Counts",
                                               "The updated play log could not be installed. The original was backed up."))
            }
        }
        for track in database.tracks where replacements.contains(track.id) || removedTracks.contains(track.id) {
            guard !activePaths.contains(track.path.lowercased()), let old = layout.trackURL(for: track.path),
                  DeviceLayout.safeFile(old) else { continue }
            do { try fm.removeItem(at: old) }
            catch { cleanupIssues.append(SyncItem(.skip, track.fields[1] ?? old.lastPathComponent,
                                                   "Old device file could not be deleted.")) }
        }
        let prior = Dictionary(uniqueKeysWithValues: database.tracks.map { ($0.id, $0) })
        let completed = Array(plan.items.prefix(copied.count))
        let deferred = plan.entries.dropFirst(copied.count).map {
            var item = SyncItem(.skip, $0.song.title, "Sync stopped before transfer.")
            item.sourceURL = $0.song.originalSource ?? $0.song.url
            return item
        }
        let metadata = verification.tracks.compactMap { track -> SyncItem? in
            guard let old = prior[track.id],
                  old.fields.filter({ $0.key != 2 }) != track.fields.filter({ $0.key != 2 }) ||
                  old.releaseTimestamp != track.releaseTimestamp || old.artworkID != track.artworkID else { return nil }
            return SyncItem(.metadata, track.fields[1] ?? "Untitled", track.fields[3] ?? "")
        }
        let playlistResults = playlists.map { SyncItem(.metadata, $0.name, "Playlist saved") }
        let removals = plan.items.filter { $0.action == .remove }.map { item in
            stopped && !plan.removedTracks.isEmpty ? SyncItem(.skip, item.title, "Sync stopped before removal.") : item
        }
        if stopped {
            let transferred = Set(copied.map { $0.path.lowercased() })
            let planned = Set(plan.entries.map { $0.path.lowercased() })
            artworkSkips += plan.artworkSongs.filter { path, _ in !planned.contains(path) || transferred.contains(path) }
                .values.map { SyncItem(.skip, $0.title, "Sync stopped before artwork was saved.") }
        }
        let podcastResult = plan.repairsPodcastIndex ? [SyncItem(.metadata, "Podcasts", "Episode index rebuilt")] : []
        let listeningResult = stopped ? [] : plan.items.filter { $0.detail == "Listening position and played status" }
        report(completed + deferred + metadata + playlistResults + removals + podcastResult + listeningResult + artworkSkips + cleanupIssues + plannedSkips)
        if writer?.skippedForSpace == true { notice(artworkWarning) }
        return copied.count
    }

    private static func load(_ device: Device, layout: DeviceLayout) throws -> (Data, Database, Signing) {
        let fm = FileManager.default
        guard Device.decodeGUID(layout.info["FireWireGUID"] as? String ?? "") == device.guid, device.guid.count == 8 else {
            throw SyncError("The selected iPod was disconnected or its FireWire GUID is missing.")
        }
        guard !fm.fileExists(atPath: layout.database.deletingLastPathComponent().appending(path: "iTunesCDB").path),
              DeviceLayout.safeFile(layout.database) else { throw SyncError("A regular iTunesDB is required to sync.") }
        let data = try Data(contentsOf: layout.database)
        return (data, try Database(data), try Signing(database: data, guid: device.guid))
    }

    private static func makeSafeDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        guard DeviceLayout.safeDirectory(directory) else { throw SyncError("The iPod music directory is invalid.") }
    }

    private static func checkSource(_ song: Song) throws {
        let values = try song.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                           .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == song.size, values.contentModificationDate == song.modificationDate else {
            throw SyncError("\(song.title) changed since the library scan. Rescan the library and try again.")
        }
    }
}
