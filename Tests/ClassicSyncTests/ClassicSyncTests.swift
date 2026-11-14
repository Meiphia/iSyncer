import Foundation
import Testing
@testable import ClassicSync

@Test func rejectsTruncatedDatabase() {
    #expect(throws: SyncError.self) { try Database(Data("mhbd".utf8)) }
}

@Test func classicTextComposesSwedishLettersAndPreservesPaths() throws {
    let decomposed = "A\u{030A}sa pa\u{030A} O\u{0308}land"
    let title = try #require(Database.stringRecord((1, decomposed)))
    #expect(Data(title.dropFirst(40)) == "Åsa på Öland".data(using: .utf16LittleEndian))
    let path = try #require(Database.stringRecord((2, decomposed)))
    #expect(Data(path.dropFirst(40)) == decomposed.data(using: .utf16LittleEndian))
}

@Test func releaseDatesCanBeAddedToExistingMedia() throws {
    var tracks = Data.record("mhlt", header: 12)
    tracks.put(0, at: 8)
    var trackSection = Data.record("mhsd", header: 96, children: [tracks])
    trackSection.put(1, at: 12)
    var main = Data.record("mhyp", header: 108)
    main[20] = 1
    var playlists = Data.record("mhlp", header: 12)
    playlists.put(1, at: 8)
    var playlistSection = Data.record("mhsd", header: 96, children: [playlists, main])
    playlistSection.put(2, at: 12)
    var original = Data.record("mhbd", header: 0xa0, children: [trackSection, playlistSection])
    original.put(2, at: 20)
    let empty = try Database(original)
    let published = Date(timeIntervalSince1970: 1_700_000_000)
    let legacy = Data(#"{"feed":"https://example.com/rss","enclosure":"https://example.com/episode.mp3"}"#.utf8)
    let metadata = try JSONDecoder().decode(PodcastMetadata.self, from: legacy)
    #expect(metadata.publishedAt == nil)

    func song(_ kind: ClassicMediaKind) -> Song {
        Song(url: URL(fileURLWithPath: "/fixture"), title: "Episode", artist: "Host", album: "Show",
             albumArtist: "", genre: "", composer: "", duration: 1000, size: 10, number: 0,
             trackCount: 0, disc: 0, discCount: 0, year: 0, bitRate: 128, sampleRate: 44100,
             kind: "Fixture", fourCC: "MP3 ", modificationDate: published, mediaKind: kind)
    }
    var podcast = song(.podcast)
    podcast.podcastMetadata = metadata
    let path = ":iPod_Control:Music:F00:P.mp3"
    let videoPath = ":iPod_Control:Music:F00:V.mp4"
    let old = try Database(empty.adding([.init(song: podcast, path: path), .init(song: song(.tvShow), path: videoPath)]))
    #expect(old.tracks.map(\.releaseTimestamp) == [0, 0])
    podcast.podcastMetadata?.publishedAt = published
    let timestamp = try #require(Database.releaseTimestamp(published))
    #expect(timestamp == 3_782_844_800)
    let updated = try Database(old.adding([], podcastUpdates: [path.lowercased(): podcast],
                                         videoReleaseDates: [videoPath.lowercased(): timestamp]))
    #expect(updated.tracks.map(\.releaseTimestamp) == [timestamp, timestamp])
    #expect(updated.tracks.map(\.id) == old.tracks.map(\.id))
    #expect(updated.tracks.map(\.fields) == old.tracks.map(\.fields))
    let edited = try Database(updated.adding([], videoReleaseDates: [videoPath.lowercased(): 0],
                                            videoTitles: [videoPath.lowercased(): "New title"],
                                            videoDescriptions: [videoPath.lowercased(): "Episode description"]))
    #expect(edited.tracks.map(\.id) == old.tracks.map(\.id))
    #expect(edited.tracks.last?.fields[1] == "New title")
    #expect(edited.tracks.last?.releaseTimestamp == 0)
    #expect(edited.tracks.last?.path == videoPath)
    #expect(edited.tracks.last?.fields[14] == "Episode description")
    let cleared = try Database(edited.adding([], videoDescriptions: [videoPath.lowercased(): ""]))
    #expect(cleared.tracks.last?.fields[14] == nil)
    let music = try Database(empty.adding([.init(song: song(.tvShow), path: videoPath),
                                           .init(song: song(.music), path: path)]))
    var counts = Data(count: 120)
    counts.replaceSubrange(0..<4, with: "mhdp".utf8)
    counts.put(96, at: 4)
    counts.put(12, at: 8)
    counts.put(2, at: 12)
    counts.put(3, at: 108)
    counts.put(timestamp, at: 112)
    let plays = try music.devicePlays(counts)
    #expect(plays.first?.total == 3)
    #expect(plays.first?.latestEvent == 1_700_000_000)
    #expect(throws: SyncError.self) { try music.devicePlays(Data(counts.dropLast())) }
    let removedVideo = [try #require(music.tracks.first).id] as Set<Int>
    let remainingMusic = try Database(music.adding([], removedTracks: removedVideo))
    #expect(try remainingMusic.devicePlays(music.playCounts(counts, removing: removedVideo)) == plays)
    let key = Song.videoSyncKey(tv: true, show: "Show", season: 1, episode: 2, title: "Original")
    #expect(key == Song.videoSyncKey(tv: true, show: "SHOW", season: 1, episode: 2, title: "Edited"))
    #expect(key != Song.videoSyncKey(tv: true, show: "Show", season: 2, episode: 2, title: "Original"))
}

@Test func classicRoundTrip() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let originalPath = environment["ISYNCER_TEST_IPOD"],
          let musicPath = environment["ISYNCER_TEST_MUSIC"] else { return }

    let fm = FileManager.default
    let sourceDevice = try Device.inspect(URL(fileURLWithPath: originalPath))
    #expect(sourceDevice.syncIssue == nil)
    let source = sourceDevice.mount.appending(path: "iPod_Control")
    let temporary = fm.temporaryDirectory.appending(path: "iSyncer-test-\(UUID())", directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: temporary) }
    let mount = temporary.appending(path: "Test iPod")
    let control = mount.appending(path: "iPod_Control")
    let iTunes = control.appending(path: "iTunes")
    try fm.createDirectory(at: iTunes, withIntermediateDirectories: true)
    try fm.copyItem(at: source.appending(path: "Device"), to: control.appending(path: "Device"))
    let originalURL = source.appending(path: "iTunes/iTunesDB")
    let dbURL = iTunes.appending(path: "iTunesDB")
    let original = try Data(contentsOf: originalURL)
    try original.write(to: dbURL)

    let testDevice = try Device.inspect(mount)
    let scanned = try await LibraryScanner.scan([URL(fileURLWithPath: musicPath)])
    let songs = scanned.songs.enumerated().map { index, song in
        guard index == 0 else { return song }
        return Song(url: song.url, title: song.title, artist: "Featured Artist", album: song.album,
                    albumArtist: "Main Artist", genre: song.genre, composer: song.composer,
                    duration: song.duration, size: song.size, number: song.number, trackCount: song.trackCount,
                    disc: song.disc, discCount: song.discCount, year: song.year, bitRate: song.bitRate,
                    sampleRate: song.sampleRate, kind: song.kind, fourCC: song.fourCC,
                    modificationDate: song.modificationDate)
    }
    let library = LocalLibrary(songs: songs, skipped: scanned.skipped)
    print("Recognized \(library.songs.count) tracks, skipped \(library.skipped)")
    #expect(library.songs.count > 0)
    #expect(library.skipped == 0)
    #expect(library.songs.allSatisfy { !$0.title.isEmpty && !$0.artist.isEmpty && !$0.album.isEmpty && $0.number > 0 })
    var manual = LocalPlaylist(name: "Manual")
    manual.paths = library.songs.reversed().map { $0.url.path }
    var smart = LocalPlaylist(name: "Smart", smart: true)
    smart.rules?[0].field = .artist
    smart.rules?[0].value = library.songs[1].artist
    smart.rules?.append(PlaylistRule())
    smart.rules?[1].value = library.songs[0].artist
    smart.matchAll = false
    smart.limit = 2
    var options = SyncOptions()
    options.playlists = [manual, smart]
    let preview = try SyncEngine.preview(library.songs, on: testDevice, options: options)
    #expect(preview.pending.count == library.songs.count)
    #expect(preview.canFit)
    let backups = temporary.appending(path: "Backups")
    let stop = SyncStop()
    let partial = try SyncEngine.apply(preview, backups: backups, stop: stop) { current, _, _ in
        if current == 0 { stop.request() }
    }
    #expect(partial == 1)
    let partialDevice = try Device.inspect(mount)
    #expect(partialDevice.trackCount == testDevice.trackCount + 1)
    let partialDB = try Database(Data(contentsOf: dbURL))
    let partialPlaylists = try partialDB.playlistUpdates()
    #expect(partialPlaylists[manual.deviceID]?.paths.count == 1)
    #expect(partialPlaylists[smart.deviceID]?.paths.count == 1)
    let rest = try SyncEngine.preview(library.songs, on: partialDevice, options: options)
    let transferred = try SyncEngine.apply(rest, backups: backups) { _, _, _ in } + partial
    #expect(transferred == library.songs.count)
    let updated = try Device.inspect(mount)
    #expect(updated.syncIssue == nil)
    #expect(updated.trackCount == testDevice.trackCount + transferred)

    let previousTracks = try Database(original).tracks
    let currentTracks = try Database(Data(contentsOf: dbURL)).tracks
    #expect(Array(currentTracks.prefix(previousTracks.count).map(\.id)) == previousTracks.map(\.id))
    let added = currentTracks.dropFirst(previousTracks.count)
    for (entry, song) in zip(added, preview.pending) {
        let path = entry.path.split(separator: ":").joined(separator: "/")
        #expect(fm.contentsEqual(atPath: song.url.path, andPath: mount.appending(path: path).path))
        #expect(entry.fields[1] == song.title)
        #expect(entry.fields[4] == song.artist)
        #expect(entry.number == song.number)
    }
    let finished = try Database(Data(contentsOf: dbURL))
    let finishedPlaylists = try finished.playlistUpdates()
    #expect(finishedPlaylists[manual.deviceID]?.paths == added.reversed().map { $0.path.lowercased() })
    #expect(finishedPlaylists[smart.deviceID]?.paths.count == 2)
    let second = try SyncEngine.preview(library.songs, on: updated, options: options)
    #expect(!second.hasChanges)
    #expect(second.alreadyOnDevice == transferred)
    #expect(throws: SyncError.self) { try SyncEngine.apply(preview, backups: backups) { _, _, _ in } }

    options.playlists = [smart]
    options.removedPlaylists = [manual.id]
    options.artwork = true
    options.useAlbumArtistForArtist = true
    let repair = try SyncEngine.preview(library.songs, on: updated, options: options)
    #expect(repair.pending.isEmpty)
    #expect(repair.artworkCandidates == transferred)
    #expect(repair.removedPlaylistCount == 1)
    let repairTransfers = try SyncEngine.apply(repair, backups: backups) { _, _, _ in }
    #expect(repairTransfers == 0)
    let repaired = try Database(Data(contentsOf: dbURL))
    #expect(try repaired.playlistUpdates()[manual.deviceID] == nil)
    for (entry, song) in zip(repaired.tracks.suffix(transferred), preview.pending) {
        #expect(entry.fields[4] == (song.albumArtist.isEmpty ? song.artist : song.albumArtist))
        #expect((entry.fields[22] ?? "") == song.albumArtist)
    }
    let repairedDevice = try Device.inspect(mount)
    let again = try SyncEngine.preview(library.songs, on: repairedDevice, options: options)
    #expect(again.pending.isEmpty)
    #expect(again.retagCount == 0)
    if environment["ISYNCER_TEST_ARTWORK"] != nil {
        let artworkDirectory = control.appending(path: "Artwork")
        let artwork = try Data(contentsOf: artworkDirectory.appending(path: "ArtworkDB"))
        #expect(artwork.isTag("mhfd", at: 0))
        #expect(artwork.u32(8) == artwork.count)
        let section = artwork.u32(4)
        let list = section + artwork.u32(section + 4)
        let firstImage = list + artwork.u32(list + 4)
        #expect(artwork.u32(list + 8) > 0)
        #expect(artwork.isTag("mhii", at: firstImage))
        #expect(repaired.tracks.suffix(transferred).contains { $0.artworkID == artwork.u32(firstImage + 16) })
        let thumbnails = [1061: 56, 1055: 128, 1068: 128, 1060: 320]
        var found: Set<Int> = []
        var object = firstImage + artwork.u32(firstImage + 4)
        for _ in 0..<artwork.u32(firstImage + 12) {
            #expect(artwork.isTag("mhod", at: object))
            let thumbnail = object + artwork.u32(object + 4)
            #expect(artwork.isTag("mhni", at: thumbnail))
            let format = artwork.u32(thumbnail + 16)
            let dimension = try #require(thumbnails[format])
            found.insert(format)
            #expect(artwork.u32(thumbnail + 32) == dimension | (dimension << 16))
            let offset = artwork.u32(thumbnail + 20)
            let length = artwork.u32(thumbnail + 24)
            #expect(length == dimension * dimension * 2)
            let filename = thumbnail + artwork.u32(thumbnail + 4)
            let nameStart = filename + 36
            let nameEnd = nameStart + artwork.u32(filename + 24)
            let name = try #require(String(data: artwork[nameStart..<nameEnd], encoding: .utf16LittleEndian))
            #expect(name == ":F\(format)_1.ithmb")
            let cache = try Data(contentsOf: artworkDirectory.appending(path: String(name.dropFirst())))
            #expect(offset + length <= cache.count)
            object += artwork.u32(object + 8)
        }
        #expect(found == Set(thumbnails.keys))
    }
    if let videoPath = environment["ISYNCER_TEST_VIDEO"] {
        let videoURL = URL(fileURLWithPath: videoPath)
        let movie = try await LibraryScanner.scanVideo(ClassicVideo(url: videoURL, title: "Test Movie"))
        let episode = try await LibraryScanner.scanVideo(ClassicVideo(url: videoURL, title: "Test Episode",
                                                                        show: "Test Show", season: 2, episode: 3))
        let podcast = LibraryScanner.podcast(library.songs[0], show: "Test Podcast")
        let media = [movie, episode, podcast]
        let mediaPreview = try SyncEngine.preview(media, on: repairedDevice)
        #expect(mediaPreview.pending.count == 3)
        let count = try SyncEngine.apply(mediaPreview, backups: backups) { _, _, _ in }
        #expect(count == 3)
        let updatedDevice = try Device.inspect(mount)
        #expect(updatedDevice.syncIssue == nil)
        #expect(updatedDevice.contents.suffix(3).map(\.kind) == [.movie, .tvShow, .podcast])
        #expect(updatedDevice.contents.last?.album == "Test Podcast")
        #expect(try !SyncEngine.preview(media, on: updatedDevice).hasChanges)
        let updatedDatabase = try Database(Data(contentsOf: dbURL))
        #expect(updatedDatabase.tracks.suffix(3).first { $0.mediaType == 64 }?.fields[19] == "Test Show")

        let episodeTrack = try #require(updatedDatabase.tracks.first { $0.fields[19] == "Test Show" })
        let musicTrack = try #require(updatedDatabase.tracks.first { $0.fields[1] == library.songs[0].title })
        let musicIndex = try #require(updatedDatabase.tracks.firstIndex { $0.id == musicTrack.id })
        let trackCount = updatedDatabase.tracks.count
        var counts = Data(count: 96 + 28 * trackCount)
        counts.replaceSubrange(0..<4, with: "mhdp".utf8)
        counts.put(96, at: 4)
        counts.put(28, at: 8)
        counts.put(trackCount, at: 12)
        counts.put(3, at: 96 + musicIndex * 28)
        counts.put(3_782_844_800, at: 100 + musicIndex * 28)
        try counts.write(to: iTunes.appending(path: "Play Counts"))
        let plays = try SyncEngine.readPlays(on: updatedDevice)
        #expect(plays.first { $0.id == musicTrack.persistentID }?.recent == 3)
        var removalOptions = SyncOptions()
        removalOptions.removedVideoIDs = [episodeTrack.persistentID]
        let removal = try SyncEngine.preview([], on: updatedDevice, options: removalOptions)
        _ = try SyncEngine.apply(removal, backups: backups) { _, _, _ in }
        let afterRemoval = try Device.inspect(mount)
        let remainingPlays = try SyncEngine.readPlays(on: afterRemoval)
        #expect(remainingPlays == plays)
        removalOptions.removedVideoIDs = []
        let key = episodeTrack.videoSyncKey
        removalOptions.excludedVideos = [key: "Test Episode"]
        let excluded = try SyncEngine.preview([episode], on: afterRemoval, options: removalOptions)
        #expect(!excluded.hasChanges)
        #expect(excluded.items.first?.action == .skip)
    }
    let snapshots = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
    #expect(snapshots.contains { (try? Data(contentsOf: $0)) == original })
    #expect(try Data(contentsOf: originalURL) == original)
    if let dump = environment["ISYNCER_TEST_OUTPUT"] {
        try Data(contentsOf: dbURL).write(to: URL(fileURLWithPath: dump))
    }
}


@Test func scanReportsDiscoveryAndTagReadingProgress() async throws {
    guard let musicPath = ProcessInfo.processInfo.environment["ISYNCER_TEST_MUSIC"] else { return }
    let progress = ProgressLog()
    let library = try await LibraryScanner.scan([URL(fileURLWithPath: musicPath)]) { progress.append($0) }
    let updates = progress.snapshot()
    guard case .finding = updates.first,
          case .reading(let processed, let total, let accepted, let skipped, _) = updates.last else {
        Issue.record("Expected discovery and completed tag-reading updates.")
        return
    }
    #expect(processed == total)
    #expect(accepted == library.songs.count)
    #expect(skipped == library.skipped)
    let counts = updates.compactMap { update -> Int? in
        if case .reading(let processed, _, _, _, _) = update { return processed }
        return nil
    }
    #expect(counts.first == 0)
    #expect(counts == counts.sorted())
    #expect(accepted > 0)
}

@Test func libraryCacheReusesOnlyUnchangedTracks() async throws {
    guard let musicPath = ProcessInfo.processInfo.environment["ISYNCER_TEST_MUSIC"] else { return }
    let source = try await LibraryScanner.scan([URL(fileURLWithPath: musicPath)])
    let track = try #require(source.songs.first)
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appending(path: "iSyncer-cache-test-\(UUID())")
    defer { try? fm.removeItem(at: temporary) }
    let folder = temporary.appending(path: "Music", directoryHint: .isDirectory)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appending(path: track.url.lastPathComponent)
    let second = folder.appending(path: "Copy.\(track.url.pathExtension)")
    try fm.copyItem(at: track.url, to: first)
    let cacheFile = temporary.appending(path: "Cache/Library.plist")
    let original = try await LibraryScanner.scan([folder])
    try LibraryCache(folders: [folder], library: original).save(to: cacheFile)
    let cache = try #require(LibraryCache.load(from: cacheFile))
    #expect(cache.snapshot(for: [folder])?.songs.map(\.title) == [track.title])
    #expect(cache.snapshot(for: [temporary]) == nil)

    let unchanged = ProgressLog()
    let reused = try await LibraryScanner.scan([folder], cache: cache) { unchanged.append($0) }
    #expect(reused.songs.count == 1)
    #expect(unchanged.snapshot().allSatisfy { if case .finding = $0 { true } else { false } })

    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: first.path)
    try fm.copyItem(at: track.url, to: second)
    let changed = ProgressLog()
    let refreshed = try await LibraryScanner.scan([folder], cache: cache) { changed.append($0) }
    #expect(refreshed.songs.count == 2)
    #expect(refreshed.songs.first { $0.url.lastPathComponent == first.lastPathComponent }?.modificationDate
            != original.songs.first?.modificationDate)
    guard case .reading(let processed, let total, _, _, _) = changed.snapshot().last else {
        Issue.record("Expected changed and new files to be read.")
        return
    }
    #expect(processed == 2 && total == 2)

    try fm.removeItem(at: first)
    let removed = try await LibraryScanner.scan([folder], cache: cache)
    #expect(removed.songs.map { $0.url.lastPathComponent } == [second.lastPathComponent])
    try Data("invalid cache".utf8).write(to: cacheFile)
    #expect(LibraryCache.load(from: cacheFile) == nil)
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []

    func append(_ update: ScanProgress) {
        lock.withLock { updates.append(update) }
    }

    func snapshot() -> [ScanProgress] {
        lock.withLock { updates }
    }
}

@Test func fillAlbumsAndRestoreIndex() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "iSyncer-retention-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let mount = root.appending(path: "iPod")
    let control = mount.appending(path: "iPod_Control")
    let deviceInfo = control.appending(path: "Device")
    let iTunes = control.appending(path: "iTunes")
    let backups = root.appending(path: "Backups")
    try fm.createDirectory(at: deviceInfo, withIntermediateDirectories: true)
    try fm.createDirectory(at: iTunes, withIntermediateDirectories: true)
    let guid = Data([1, 2, 3, 4, 5, 6, 7, 8])
    try Data("FamilyID: 11\nFireWireGUID: 0x0102030405060708\n".utf8).write(to: deviceInfo.appending(path: "SysInfo"))

    var trackList = Data.record("mhlt", header: 12)
    trackList.put(0, at: 8)
    var tracks = Data.record("mhsd", header: 96, children: [trackList])
    tracks.put(1, at: 12)
    var main = Data.record("mhyp", header: 108)
    main[20] = 1
    var playlistList = Data.record("mhlp", header: 12)
    playlistList.put(1, at: 8)
    var playlists = Data.record("mhsd", header: 96, children: [playlistList, main])
    playlists.put(2, at: 12)
    var empty = Data.record("mhbd", header: 0xa0, children: [tracks, playlists])
    empty.put(2, at: 20)
    empty[0x30] = 1
    try Signing.signEmptyDatabase(&empty, guid: guid)
    let database = iTunes.appending(path: "iTunesDB")
    try empty.write(to: database)
    let device = try Device.inspect(mount)
    #expect(device.syncIssue == nil)

    func source(_ title: String, kind: ClassicMediaKind) throws -> Song {
        let url = root.appending(path: title + ".mp3")
        try Data(count: 1024).write(to: url)
        let timestamp = try #require(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return Song(url: url, title: title, artist: "Artist", album: kind == .podcast ? "Show" : "Album",
                    albumArtist: "", genre: "", composer: "", duration: 1000, size: 1024,
                    number: 0, trackCount: 0, disc: 0, discCount: 0, year: 0, bitRate: 128, sampleRate: 44100,
                    kind: "Fixture", fourCC: "MP3 ", modificationDate: timestamp, mediaKind: kind,
                    podcastMetadata: kind == .podcast
                        ? PodcastMetadata(feed: "https://example.com/rss", enclosure: "https://example.com/\(title)") : nil)
    }

    let one = try source("One", kind: .music)
    let two = try source("Two", kind: .music)
    let episode = try source("Episode", kind: .podcast)
    var options = SyncOptions()
    options.fillAlbums = [[one, two]]
    let base = try SyncEngine.preview([episode], on: device)
    options.fillReserve = max(0, base.available - 1_048_576 - Int64(empty.count) - 20_000)
    let insufficient = try SyncEngine.preview([episode], on: device, options: options)
    #expect(insufficient.pending.map(\.title) == ["Episode"])
    options.fillReserve = 0
    let preview = try SyncEngine.preview([episode], on: device, options: options)
    #expect(preview.pending.map(\.title) == ["Episode", "One", "Two"])
    #expect(try SyncEngine.apply(preview, backups: backups) { _, _, _ in } == 3)
    let withMedia = try Device.inspect(mount)
    let backup = try #require(fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "backup" })
    let restore = try SyncEngine.previewRestore(backup, on: withMedia)
    #expect(restore.canRestore)
    #expect(restore.unlistedFiles == 3)

    let live = try Database(Data(contentsOf: database))
    let podcastIndex = try #require(live.tracks.firstIndex { $0.fields[1] == episode.title })
    let playLog = iTunes.appending(path: "Play Counts")
    var counts = Data(count: 96 + 12 * live.tracks.count)
    counts.replaceSubrange(0..<4, with: "mhdp".utf8)
    counts.put(96, at: 4)
    counts.put(12, at: 8)
    counts.put(live.tracks.count, at: 12)
    counts.put(1, at: 96 + podcastIndex * 12)
    try counts.write(to: playLog)
    #expect(try SyncEngine.previewRestore(backup, on: withMedia).positionalPlayLogExists)
    options = SyncOptions()
    options.podcastLimits["Show"] = PodcastSyncLimit(latest: .max, removeOlder: false, removePlayed: true)
    let expired = try SyncEngine.preview([episode], on: withMedia, options: options)
    #expect(expired.removedTrackCount == 1)
    #expect(expired.playedPodcastSources == [episode.url])
    options.podcastLimits["Show"] = PodcastSyncLimit(latest: .max, pinned: [episode.url], removeOlder: false, removePlayed: true)
    let pinned = try SyncEngine.preview([episode], on: withMedia, options: options)
    #expect(pinned.removedTrackCount == 0)
    try fm.removeItem(at: playLog)
    #expect(throws: SyncError.self) { try SyncEngine.apply(expired, backups: backups) { _, _, _ in } }
    try SyncEngine.restore(restore, backups: backups)
    #expect(try Data(contentsOf: database) == empty)
    #expect(try Device.inspect(mount).trackCount == 0)

    let firstTV = try source("First TV episode", kind: .tvShow)
    let pinnedTV = try source("Pinned TV episode", kind: .tvShow)
    let movie = try source("Movie", kind: .movie)
    let television = try SyncEngine.preview([firstTV, pinnedTV, movie], on: Device.inspect(mount))
    #expect(try SyncEngine.apply(television, backups: backups) { _, _, _ in } == 3)
    let withTelevision = try Device.inspect(mount)
    let tvDB = try Database(Data(contentsOf: database))
    let firstIndex = try #require(tvDB.tracks.firstIndex { $0.fields[1] == firstTV.title })
    let pinnedTrack = try #require(tvDB.tracks.first { $0.fields[1] == pinnedTV.title })
    let watchedKey = tvDB.tracks[firstIndex].videoSyncKey
    var tvCounts = Data(count: 96 + 12 * tvDB.tracks.count)
    tvCounts.replaceSubrange(0..<4, with: "mhdp".utf8)
    tvCounts.put(96, at: 4)
    tvCounts.put(12, at: 8)
    tvCounts.put(tvDB.tracks.count, at: 12)
    tvCounts.put(1, at: 96 + firstIndex * 12)
    try tvCounts.write(to: playLog)
    #expect(try SyncEngine.readPlays(on: withTelevision).isEmpty)
    let watched = try SyncEngine.readPlays(on: withTelevision, includeVideo: true).filter(\.played)
    #expect(watched.compactMap(\.videoSyncKey) == [watchedKey])
    var tvOptions = SyncOptions()
    tvOptions.expectedWatchedTVKeys = [watchedKey]
    tvOptions.expiredTVKeys = [watchedKey, pinnedTrack.videoSyncKey]
    tvOptions.retainedTVKeys = [pinnedTrack.videoSyncKey]
    let tvPreview = try SyncEngine.preview([], on: withTelevision, options: tvOptions)
    #expect(tvPreview.items.filter { $0.action == .remove }.map(\.title) == [firstTV.title])
    try fm.removeItem(at: playLog)
    #expect(throws: SyncError.self) { try SyncEngine.apply(tvPreview, backups: backups) { _, _, _ in } }
    try tvCounts.write(to: playLog)
    #expect(try SyncEngine.apply(tvPreview, backups: backups) { _, _, _ in } == 0)
    #expect(Set(try Device.inspect(mount).contents.map(\.title)) == [pinnedTV.title, movie.title])

    // Exercise bookmark-only updates on existing media with a positional play log.
    let book = try source("Audiobook", kind: .audiobook)
    let media = [episode, book, pinnedTV]
    let addSpoken = try SyncEngine.preview(media, on: Device.inspect(mount))
    #expect(try SyncEngine.apply(addSpoken, backups: backups) { _, _, _ in } == 2)
    let withSpoken = try Device.inspect(mount)
    let beforeProgress = try Database(Data(contentsOf: database))
    var bookmarks = Data(count: 96 + 28 * beforeProgress.tracks.count)
    bookmarks.replaceSubrange(0..<4, with: "mhdp".utf8)
    bookmarks.put(96, at: 4)
    bookmarks.put(28, at: 8)
    bookmarks.put(beforeProgress.tracks.count, at: 12)
    for (index, track) in beforeProgress.tracks.enumerated() where media.contains(where: { $0.title == track.fields[1] }) {
        bookmarks.put(256, at: 96 + index * 28 + 16)
        bookmarks.put(700, at: 96 + index * 28 + 8)
    }
    try bookmarks.write(to: playLog)
    let originalPlays = try SyncEngine.readPlays(on: withSpoken, includeVideo: true)
    #expect(originalPlays.filter { $0.bookmarkMilliseconds == 700 }.count == 3)

    var progress = SyncOptions()
    // Even a matching Play Counts bookmark needs committing to the database.
    progress.listening = [episode.url: .init(seconds: 0.7, played: false),
                          book.url: .init(seconds: 0.4, played: false),
                          pinnedTV.url: .init(seconds: 0.5, played: false)]
    let update = try SyncEngine.preview(media, on: withSpoken, options: progress)
    #expect(update.pending.isEmpty)
    #expect(update.items.filter { $0.detail == "Playback position and played status" }.count == 3)
    #expect(try SyncEngine.apply(update, backups: backups) { _, _, _ in } == 0)
    let updatedPlays = try SyncEngine.readPlays(on: withSpoken, includeVideo: true)
    #expect(updatedPlays.first { $0.kind == .podcast }?.bookmarkMilliseconds == 700)
    #expect(updatedPlays.first { $0.kind == .audiobook }?.bookmarkMilliseconds == 400)
    #expect(updatedPlays.first { $0.kind == .tvShow }?.bookmarkMilliseconds == 500)
    let onDisk = try Database(Data(contentsOf: database))
    #expect(try onDisk.devicePlays(nil, includeVideo: true) == updatedPlays)
    #expect(try !SyncEngine.preview(media, on: withSpoken, options: progress).hasChanges)

    // An item already on the iPod can sync its position independently of media selection.
    let matchedBook = try #require(updatedPlays.first { $0.kind == .audiobook })
    var alreadyOnDevice = SyncOptions()
    alreadyOnDevice.existingListening = [matchedBook.id: .init(seconds: 0.9, played: false)]
    alreadyOnDevice.expectedListening = [matchedBook.id: matchedBook.listeningState]
    let bookmarkOnly = try SyncEngine.preview([], on: withSpoken, options: alreadyOnDevice)
    #expect(bookmarkOnly.hasChanges && bookmarkOnly.pending.isEmpty)
    try SyncEngine.validatePlaybackSnapshot(bookmarkOnly)
    #expect(try SyncEngine.apply(bookmarkOnly, backups: backups) { _, _, _ in } == 0)
    #expect(try SyncEngine.readPlays(on: withSpoken).first { $0.kind == .audiobook }?.bookmarkMilliseconds == 900)
    #expect(throws: SyncError.self) { try SyncEngine.validatePlaybackSnapshot(bookmarkOnly) }

}

@Test func playbackProgressReconciliation() {
    func position(_ seconds: Double) -> ClassicListeningState { .init(seconds: seconds, played: false) }
    let empty = position(0), old = position(60), mac = position(180), iPod = position(240)
    #expect(ClassicListeningState.reconcile(mac: mac, iPod: empty, last: nil) == .useMac)
    #expect(ClassicListeningState.reconcile(mac: empty, iPod: iPod, last: nil) == .useIPod)
    #expect(ClassicListeningState.reconcile(mac: mac, iPod: iPod, last: nil) == .conflict)
    #expect(ClassicListeningState.reconcile(mac: mac, iPod: old, last: old) == .useMac)
    #expect(ClassicListeningState.reconcile(mac: old, iPod: iPod, last: old) == .useIPod)
    #expect(ClassicListeningState.reconcile(mac: mac, iPod: iPod, last: old) == .conflict)
    #expect(ClassicListeningState.reconcile(mac: old, iPod: position(60.2), last: nil) == .same)
    #expect(ClassicListeningState.reconcile(mac: empty, iPod: old, last: old) == .useMac)
}
