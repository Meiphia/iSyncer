import ClassicSync
import Foundation
import Testing
@testable import iSyncer

@Test func repeatedIPodPlaysProduceDistinctScrobbles() {
    let now = 1_800_000_000
    let track = Track(id: "song.mp3", size: 1, modified: 0, info: TagInfo(), dateAdded: 0)
    let repeats = LastFM.deviceEntries(for: track, count: 5, latestEvent: now - 60, duration: 180, now: now)
    #expect(repeats.count == 5)
    #expect(Set(repeats).count == 5)
    #expect(repeats.map(\.timestamp) == (0..<5).map { now - 60 - 180 * (5 - $0) })
    #expect(LastFM.deviceEntries(for: track, count: 0, latestEvent: now - 60, duration: 180, now: now).isEmpty)
    let oldest = now - 14 * 86_400 + 600
    let nearCutoff = LastFM.deviceEntries(for: track, count: 5, latestEvent: oldest + 185, duration: 180, now: now)
    #expect(nearCutoff.count == 5 && Set(nearCutoff).count == 5)
    #expect(nearCutoff.allSatisfy { $0.timestamp >= oldest })
    #expect(LastFM.deviceEntries(for: track, count: 5, latestEvent: oldest - 1, duration: 180, now: now).isEmpty)
}

@Test @MainActor func podcastDownloadLimitKeepsNewerArchiveCopyAndFetchesOnlyMissingSlots() {
    let base = URL(string: "https://example.org/")!
    func episode(_ name: String, day: Double) -> PodcastEpisode {
        PodcastEpisode(title: name, enclosure: base.appending(path: name), fileExtension: "mp3",
                       publishedAt: Date(timeIntervalSince1970: day * 86_400))
    }
    let newest = episode("newest", day: 8)
    let archived = episode("archive", day: 7)
    let older = episode("older", day: 5)
    let copy = PodcastSubscriptions.Download(url: URL(fileURLWithPath: "/archive.mp3"), metadata:
        PodcastMetadata(feed: base.absoluteString, enclosure: archived.enclosure.absoluteString,
                        publishedAt: archived.publishedAt), date: .distantPast)
    let selected = PodcastSubscriptions.downloadWindow(episodes: [newest, older], existing: [copy], limit: 2)
    #expect(selected == Set([newest, archived].map(\.enclosure.absoluteString)))
}

@Test func podcastSyncDefaultRespectsExplicitAllAndLegacyCatchUp() {
    var settings = ClassicSyncSettings()
    #expect(settings.podcastPolicy(for: "Daily").mode == .useDefault)
    settings.defaultPodcastLimit = 5
    #expect(settings.podcastPolicy(for: "Daily").mode == .hardCap)
    #expect(settings.podcastPolicy(for: "Daily").limit == 5)
    var all = PodcastRetention()
    all.select(.all)
    settings.setPodcastRetention(all, for: "Series")
    settings.setPodcastRetention(PodcastRetention(limit: 2, unplayedOnly: true), for: "News")
    #expect(settings.podcastPolicy(for: "Series").mode == .all)
    #expect(settings.podcastPolicy(for: "News").mode == .catchUp)
}

@Test func movingConversionCachePreservesFilesAndExcludesThemFromScans() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let support = root.appending(path: "Support")
    let library = root.appending(path: "Library")
    let old = ConversionCache(defaultFolder: support, parent: nil)
    let destination = ConversionCache(defaultFolder: support, parent: library)
    try fm.createDirectory(at: library.appending(path: "TV/Cache"), withIntermediateDirectories: true)
    try fm.createDirectory(at: old.audio, withIntermediateDirectories: true)
    try fm.createDirectory(at: old.video, withIntermediateDirectories: true)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let video = old.video.appending(path: "Cached.mov")
    try Data([1]).write(to: video)
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: video.path)
    try Data([2]).write(to: old.audio.appending(path: "Cached.m4a"))
    try Data([3]).write(to: old.audio.appending(path: "Cached.m4a.cover"))
    try Data([4]).write(to: library.appending(path: "TV/Cache/Real Episode.mov"))
    try Data([5]).write(to: library.appending(path: "Real Track.m4a"))

    #expect(old.hasFiles)
    try destination.prepare()
    #expect(try old.moveFiles(to: destination) == 0)
    #expect(!old.hasFiles)
    #expect(try Data(contentsOf: destination.audio.appending(path: "Cached.m4a.cover")) == Data([3]))
    #expect(try destination.video.appending(path: "Cached.mov").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    #expect(VideoScanner.scan(root: library).map(\.id) == ["TV/Cache/Real Episode.mov"])
    #expect(Scanner.scan(root: library, existing: [:]) { _, _ in }.tracks.map(\.id) == ["Real Track.m4a"])
}

@Test func cacheLocationRejectsAnUnrelatedNonemptyCacheFolder() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let destination = ConversionCache(defaultFolder: root, parent: root)
    try fm.createDirectory(at: destination.folder, withIntermediateDirectories: true)
    let userFile = destination.folder.appending(path: "Keep.txt")
    try Data([1]).write(to: userFile)
    #expect(throws: CocoaError.self) { try destination.prepare() }
    #expect(!ConversionCache.isManagedFolder(destination.folder))
    #expect(try Data(contentsOf: userFile) == Data([1]))
}

@Test func videoMetadataSurvivesMovingAFileAndDoesNotFollowItsOldName() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let path = "TV/Show/Season 1/01. Episode.mkv"
    let newPath = "TV/Show/Season 2/01. Episode.mkv"
    let original = root.appendingPathComponent(path)
    let moved = root.appendingPathComponent(newPath)
    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data(repeating: 1, count: 1_500_000)
    try bytes.write(to: original)
    let store = VideoMetadataStore(folder: root.appendingPathComponent("Edits"))
    let edit = VideoMetadataEdit(title: "Edited Title", releaseDate: Date(timeIntervalSince1970: 123456),
                                 artwork: Data([1, 2, 3]), overview: "Edited description")
    try store.save(edit, at: store.legacyLocation(for: original))
    let previous = VideoScanner.scan(root: root)
    try fm.moveItem(at: original, to: moved)
    let firstScan = VideoScanner.scan(root: root)
    let migrated = store.resolve(firstScan, root: root, previous: previous)
    let location = try #require(migrated[newPath])
    #expect(store.read(location) == edit)
    #expect(firstScan.first?.season == 2)

    let renamedPath = "TV/Show/Season 2/02. Renamed.mkv"
    try fm.moveItem(at: moved, to: root.appendingPathComponent(renamedPath))
    try Data(repeating: 2, count: bytes.count).write(to: original)
    let resolved = store.resolve(VideoScanner.scan(root: root), root: root)
    #expect(resolved[renamedPath] == location)
    #expect(resolved[path] == nil)
}

@Test func relinkPreviewsMatchingPathsAndRejectsFoldersInPlaceOfMedia() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("Previous")
    let destination = root.appendingPathComponent("Moved")
    try fm.createDirectory(at: destination.appendingPathComponent("folder.mkv"), withIntermediateDirectories: true)
    try Data([1]).write(to: destination.appendingPathComponent("episode.mkv"))
    let preview = try LibraryRelink.inspect(source: source, destination: destination,
                                           paths: ["episode.mkv", "folder.mkv", "missing.mkv"])
    #expect(preview.matched == 1)
    #expect(preview.missing == ["folder.mkv", "missing.mkv"])
}

@Test func smartPlaylistCanFilterForUnplayedMusicAddedThisMonth() throws {
    let formatter = ISO8601DateFormatter()
    let now = try #require(formatter.date(from: "2026-11-14T14:00:00Z"))
    let october = try #require(formatter.date(from: "2026-10-15T14:00:00Z"))
    let recent = Track(id: "Recent.mp3", size: 1, modified: 0, info: TagInfo(), dateAdded: now.timeIntervalSince1970)
    var old = recent
    old.id = "Old.mp3"
    old.dateAdded = october.timeIntervalSince1970
    var played = recent
    played.id = "Played.mp3"
    played.playCount = 1
    var addedThisMonth = SmartRule()
    addedThisMonth.field = .dateAdded
    addedThisMonth.op = .thisMonth
    var unplayed = SmartRule()
    unplayed.field = .playCount
    unplayed.op = .isEqual
    var playlist = SmartPlaylist()
    playlist.rules = [addedThisMonth, unplayed]
    #expect(playlist.evaluate([recent, old, played], unchecked: [], now: now) == [recent.id])
}

@Test func renumberedEpisodeReusesSeasonFolderAndMovesMatchingSidecars() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let path = "TV/Show/Season 1/03. My Episode.mkv"
    let source = root.appendingPathComponent(path)
    let sourceFolder = source.deletingLastPathComponent()
    let targetFolder = root.appendingPathComponent("TV/Show/S02")
    try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
    let sourceNames = ["03. My Episode.mkv", "03. My Episode.en.srt", "03. My Episode-thumb.jpg", "03. My Episode.nfo", "poster.jpg"]
    for name in sourceNames { try Data(name.utf8).write(to: sourceFolder.appendingPathComponent(name)) }
    let video = VideoScanner.parse(path, size: 1, modified: 0)
    let newPath = try #require(VideoScanner.episodePath(for: video, season: 2, episode: 7, at: root))
    #expect(newPath == "TV/Show/S02/S02E07 - My Episode.mkv")
    let destination = root.appendingPathComponent(newPath)
    let move = EpisodeMove(source: source, destination: destination)
    let metadata = VideoMetadataStore(folder: root.appendingPathComponent("Edits"))
    let title = VideoMetadataEdit(title: "Edited title")
    let contents = try Data(contentsOf: source)
    let key = try metadata.contentLocation(for: source, size: Int64(contents.count))

    // A sidecar collision leaves all of the source files untouched.
    let conflictingSubtitle = targetFolder.appendingPathComponent("S02E07 - My Episode.en.srt")
    try Data([9]).write(to: conflictingSubtitle)
    #expect(throws: SyncError.self) { try move.perform(in: root) {} }
    #expect(try Data(contentsOf: conflictingSubtitle) == Data([9]))
    #expect(fm.fileExists(atPath: source.path))
    try fm.removeItem(at: conflictingSubtitle)

    // A failure writing metadata rolls the move back.
    #expect(throws: CocoaError.self) {
        try move.perform(in: root) { throw CocoaError(.fileWriteNoPermission) }
    }
    #expect(try Set(fm.contentsOfDirectory(atPath: sourceFolder.path)) == Set(sourceNames))
    #expect(try fm.contentsOfDirectory(atPath: targetFolder.path).isEmpty)

    try move.perform(in: root) { try metadata.save(title, at: key) }
    #expect(try fm.contentsOfDirectory(atPath: sourceFolder.path) == ["poster.jpg"])
    #expect(fm.fileExists(atPath: conflictingSubtitle.path))
    #expect(try Data(contentsOf: destination) == contents)
    let scanned = VideoScanner.scan(root: root)
    #expect(scanned.first?.season == 2)
    #expect(scanned.first?.episode == 7)
    #expect(metadata.resolve(scanned, root: root)[newPath] == key)
    #expect(metadata.read(key) == title)
}

@Test func renumberingAnEpisodeKeepsItsExplicitSyncSettings() {
    let old = VideoScanner.parse("TV/Show/Season 1/Show.S01E03.mkv", size: 1, modified: 0)
    let new = VideoScanner.parse("TV/Show/Season 2/Show.S02E07.mkv", size: 1, modified: 0)
    var settings = ClassicSyncSettings()
    settings.selectTVEpisode(old, included: true)
    settings.tvRetention = [old.show: TVRetention(limit: 5, pinned: [old.id])]
    settings.excludedVideos = [old.classicTVKey: old.displayTitle]
    settings.moveEpisodes([(old, new)])
    #expect(!settings.includesTVEpisode(old))
    #expect(settings.includesTVEpisode(new))
    #expect(settings.tvRetention?[new.show]?.pinned == [new.id])
    #expect(settings.excludedVideos?[old.classicTVKey] == nil)
    #expect(settings.excludedVideos?[new.classicTVKey] == old.displayTitle)
}

@Test func batchEpisodeMovesCanReuseOccupiedSourcePaths() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("TV/Show/Season 1")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appendingPathComponent("S01E01.mkv")
    let second = folder.appendingPathComponent("S01E02.mkv")
    try Data([1]).write(to: first)
    try Data([2]).write(to: second)
    let videos = VideoScanner.scan(root: root)
    let edits = videos.map { EpisodeNumberEdit(video: $0, season: 1, episode: $0.episode + 1) }
    let plan = try EpisodeNumberEdit.plan(edits, videos: videos, root: root)
    #expect(plan.count == 2)
    try EpisodeMove.perform(plan.map(\.files), in: root) {}
    #expect(!fm.fileExists(atPath: first.path))
    #expect(try Data(contentsOf: second) == Data([1]))
    #expect(try Data(contentsOf: folder.appendingPathComponent("S01E03.mkv")) == Data([2]))
}

@Test func videoHealthFindsNumberingAndDuplicateIssues() {
    let paths = [
        "TV/Show/Season 1/Show.S02E03.mkv",
        "TV/Show/Season 2/03. Episode.mkv",
        "TV/Show/Season 2/Untitled.mkv",
        "Movies/Film (2009)/File.mkv",
        "Movies/Film (2009)/Other.mp4"
    ]
    let issues = VideoHealthIssue.find(in: paths.map { VideoScanner.parse($0, size: 1, modified: 0) })
    #expect(issues.filter { $0.title == "Duplicate episode number" }.count == 2)
    #expect(issues.filter { $0.title == "Season folder mismatch" }.count == 1)
    #expect(issues.filter { $0.title == "Missing episode number" }.count == 1)
    #expect(issues.filter { $0.title == "Possible duplicate movie" }.count == 2)
}

@Test func tvUpNextResumesMostRecentUnfinishedEpisodeOrSelectsFirstUnwatched() {
    let pilot = VideoScanner.parse("TV/Show/Season 1/S01E01.mkv", size: 1, modified: 0)
    let second = VideoScanner.parse("TV/Show/Season 1/S01E02.mkv", size: 1, modified: 0)
    let later = VideoScanner.parse("TV/Show/Season 2/S02E01.mkv", size: 1, modified: 0)
    let special = VideoScanner.parse("TV/Show/Season 0/S00E01.mkv", size: 1, modified: 0)
    let episodes = [special, later, pilot, second]
    var states: [String: VideoWatchHistory.State] = [pilot.id: .init(watched: true)]
    #expect(VideoItem.upNext(in: episodes) { states[$0.id] ?? .init() }?.episode == second)
    states[second.id] = .init(seconds: 60, updated: Date(timeIntervalSince1970: 1))
    states[later.id] = .init(seconds: 125, updated: Date(timeIntervalSince1970: 2))
    let resumed = VideoItem.upNext(in: episodes) { states[$0.id] ?? .init() }
    #expect(resumed?.episode == later)
    #expect(resumed?.position == 125)
    #expect(VideoItem.upNext(in: episodes) { _ in .init(watched: true) } == nil)
}
