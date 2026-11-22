import Foundation
import ClassicSync
import Testing
@testable import iSyncer

@Test func multipleFoldersKeepIdenticalPathsDistinctAndReadCrossFolderPlaylists() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let first = base.appending(path: "First")
    let second = base.appending(path: "Second")
    for folder in [first, second] {
        try fm.createDirectory(at: folder.appending(path: "Album"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(path: "Album/Track.m4a"))
    }
    let externalID = second.appending(path: "Album/Track.m4a").path
    try ("#EXTM3U\nAlbum/Track.m4a\n" + externalID + "\n").write(to: first.appending(path: "Both.m3u8"), atomically: true, encoding: .utf8)
    let result = LibraryFolders.scan([first, second], anchor: first, existing: [:], aliases: [:]) { _, _ in }
    #expect(Set(result.scan.tracks.map(\.id)) == ["Album/Track.m4a", externalID])
    #expect(result.scan.playlists.first?.trackIDs == ["Album/Track.m4a", externalID])
    let cached = Dictionary(uniqueKeysWithValues: result.scan.tracks.map { ($0.id, $0) })
    let again = LibraryFolders.scan([first, second], anchor: first, existing: cached, aliases: [:]) { _, _ in }
    #expect(again.scan.added == 0 && again.scan.updated == 0 && again.scan.removed == 0)
    try fm.moveItem(at: second, to: base.appending(path: "Disconnected"))
    let offline = LibraryFolders.scan([first, second], anchor: first, existing: cached, aliases: [:]) { _, _ in }
    #expect(offline.scan.tracks.count == 2)
    #expect(offline.unavailable == [externalID])
}

@Test func libraryFoldersRejectOverlapAndResolveAdditionalVideoPaths() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let folder = base.appending(path: "TV")
    let season = folder.appending(path: "Scrubs/Season 1")
    try fm.createDirectory(at: season, withIntermediateDirectories: true)
    let original = season.appending(path: "02. My Mentor.mkv")
    try Data([1]).write(to: original)
    #expect(throws: (any Error).self) { try LibraryFolders.adding([season], to: [folder]) }
    #expect(throws: (any Error).self) { try LibraryFolders.adding([base], to: [folder]) }
    #expect(try LibraryFolders.adding([folder], to: [folder]) == [folder])
    let found = try #require(VideoScanner.scan(root: folder, absoluteIDs: true).first)
    #expect(found.show == "Scrubs" && found.season == 1 && found.episode == 2)
    #expect(found.id == original.path)
    #expect(base.appendingLibraryPath(found.id) == original)
    let plan = try EpisodeNumberEdit.plan([EpisodeNumberEdit(video: found, season: 2, episode: 3)],
                                         videos: [found], root: base.appending(path: "Music"), additionalRoots: [folder])
    #expect(plan.first?.updated.id == folder.appending(path: "Scrubs/Season 2/S02E03 - My Mentor.mkv").path)
    #expect(plan.first?.files.source == original)
    #expect(plan.first?.files.destination == folder.appending(path: "Scrubs/Season 2/S02E03 - My Mentor.mkv"))
    let metadata = VideoMetadataStore(folder: base.appending(path: "Edits"))
    let edit = VideoMetadataEdit(title: "Retained metadata")
    try metadata.save(edit, at: metadata.legacyLocation(for: original))
    #expect(metadata.resolve([found], root: base.appending(path: "Music"))[found.id] != nil)
    try EpisodeMove.perform(plan.map(\.files), in: base.appending(path: "Music"), additionalRoots: [folder]) {}
    let updated = VideoScanner.scan(root: folder, absoluteIDs: true)
    let locations = metadata.resolve(updated, root: base.appending(path: "Music"), previous: [found])
    let move = try #require(plan.first)
    let location = try #require(locations[move.updated.id])
    #expect(metadata.read(location) == edit)
}

@Test @MainActor func legacySingleFolderLibraryKeepsItsIDsAndHistoryWhenAddingAnotherFolder() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let first = base.appending(path: "Original")
    let second = base.appending(path: "Additional")
    let storage = base.appending(path: "Support")
    for folder in [first, second, storage] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data([1]).write(to: first.appending(path: "Original.m4a"))
    try Data([2]).write(to: second.appending(path: "Additional.m4a"))
    var prior = try #require(Scanner.scan(root: first, existing: [:]) { _, _ in }.tracks.first)
    prior.playCount = 17
    prior.rating = 5
    prior.resumePosition = 123
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([prior]))
    let oldIndex: [String: Any] = ["root": first.path, "tracks": encoded, "playlists": [], "unchecked": [prior.id]]
    try JSONSerialization.data(withJSONObject: oldIndex).write(to: storage.appending(path: "library.json"))
    let library = LibraryStore(storageFolder: storage)
    library.load()
    #expect(library.libraryFolders.map(\.path) == [first.path])
    try library.addFolders([second])
    for _ in 0..<500 where library.isScanning || library.isScanningVideos { try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.tracks.count == 2)
    #expect(library.track(prior.id)?.playCount == 17)
    #expect(library.track(prior.id)?.rating == 5)
    #expect(library.track(prior.id)?.resumePosition == 123)
    #expect(!library.isChecked(prior.id))
    #expect(library.url(forID: prior.id) == first.appending(path: "Original.m4a"))
    library.saveNowBlocking()
}

@Test @MainActor func removingOriginalFolderKeepsOtherSourceHistoryAndSurvivesReload() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let first = base.appending(path: "First")
    let second = base.appending(path: "Second")
    let storage = base.appending(path: "Support")
    for folder in [first, second, storage] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data([1]).write(to: first.appending(path: "A.m4a"))
    try Data([2]).write(to: second.appending(path: "B.m4a"))
    let library = LibraryStore(storageFolder: storage)
    try library.addFolders([first, second])
    for _ in 0..<500 where library.isScanning || library.isScanningVideos { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!library.isScanning && !library.isScanningVideos)
    let id = second.appending(path: "B.m4a").path
    library.setRating([id], 4)
    library.recordPlay(id)
    library.setChecked([id], false)
    let playlist = library.createPlaylist(name: "Both", trackIDs: ["A.m4a", id])
    try library.removeFolder(first)
    #expect(library.tracks.map(\.id) == [id])
    #expect(library.playlist(playlist)?.trackIDs == [id])
    #expect(fm.fileExists(atPath: first.appending(path: "A.m4a").path))
    library.scan()
    for _ in 0..<500 where library.isScanning || library.isScanningVideos { try await Task.sleep(for: .milliseconds(10)) }
    library.saveNowBlocking()
    let reopened = LibraryStore(storageFolder: storage)
    reopened.load()
    #expect(reopened.libraryFolders.map(\.path) == [second.path])
    #expect(reopened.url(forID: id) == second.appending(path: "B.m4a"))
    #expect(reopened.track(id)?.playCount == 1)
    #expect(reopened.track(id)?.rating == 4)
    #expect(!reopened.isChecked(id))
    try reopened.removeFolder(second)
    #expect(reopened.libraryRoot == nil && reopened.libraryFolders.isEmpty && reopened.tracks.isEmpty)
    library.saveNowBlocking()
}

private final class MemoryPreferences: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func synchronize() -> Bool { true }
}

@Test @MainActor func finderAutoOpenSettingRestoresOnlyItsOwnPreference() throws {
    for initial: Bool? in [nil, false, true] {
        let local = MemoryPreferences()
        let system = MemoryPreferences()
        system.set(initial, forKey: FinderAutoOpen.systemKey)
        system.set("preserved", forKey: "unrelated")
        let settings = FinderAutoOpen(defaults: local, system: system)
        try settings.setEnabled(true)
        #expect(system.bool(forKey: FinderAutoOpen.systemKey))
        let reopened = FinderAutoOpen(defaults: local, system: system)
        #expect(reopened.enabled)
        try reopened.setEnabled(false)
        #expect(system.object(forKey: FinderAutoOpen.systemKey) as? Bool == initial)
        #expect(system.object(forKey: "unrelated") as? String == "preserved")
        try reopened.setEnabled(true)
        system.set(false, forKey: FinderAutoOpen.systemKey)
        try reopened.setEnabled(false)
        #expect(system.object(forKey: FinderAutoOpen.systemKey) as? Bool == false)
    }
}
