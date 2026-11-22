import AppKit
import Foundation
import Testing
@testable import iSyncer

@Test @MainActor func artistAliasGroupsMergePersistAndUnlink() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LibraryCollection(folder: folder)
    try store.setArtist("Emma Essex", aliases: ["Kitsune^2", "Renard"])
    try store.setArtist("Another Name", aliases: ["Elsewhere"])
    try store.setArtist("Emma Essex", aliases: ["Elsewhere"])
    #expect(store.artist("KITSUNE^2") == "Emma Essex")
    #expect(store.artist("Another Name") == "Emma Essex")
    #expect(store.artist("Unrelated") == "Unrelated")
    let reopened = LibraryCollection(folder: folder)
    #expect(reopened.artist("renard") == "Emma Essex")
    try reopened.unlink("Renard")
    #expect(reopened.artist("Renard") == "Renard")
    #expect(reopened.artist("Elsewhere") == "Emma Essex")
}

@Test func albumQualityUsesEditionOverridesAndFallsBackToDeviceDefault() {
    var info = TagInfo()
    info.album = "Album"
    info.albumArtist = "Artist"
    var track = Track(id: "Artist/Album/Disc 1/01.m4a", size: 1000, modified: 0, info: info, dateAdded: 0)
    var settings = ClassicSyncSettings()
    settings.musicAACBitrate = 256
    #expect(settings.aacBitrate(for: track) == 256)
    settings.setAlbumBitrate(0, edition: track.classicEditionKey)
    #expect(settings.aacBitrate(for: track) == 0)
    settings.setAlbumBitrate(192, edition: track.classicEditionKey)
    track.id = "Artist/Album/Disc 2/02.m4a"
    #expect(settings.aacBitrate(for: track) == 192)
    track.id = "Artist/Deluxe Edition/01.m4a"
    #expect(settings.aacBitrate(for: track) == 256)
}

@Test @MainActor func galleryCopiesArtworkAndPersistsItsSelectedCover() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
    let source = root.appending(path: "front.png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: source)
    let folder = root.appending(path: "Collection")
    let collection = LibraryCollection(folder: folder)
    try collection.addPicture(source, label: "Front", edition: "edition")
    let picture = try #require(collection.gallery(for: "edition").pictures.first)
    try collection.select(picture.id, edition: "edition")
    try fm.removeItem(at: source)
    let reopened = LibraryCollection(folder: folder)
    #expect(reopened.selectedArtwork(for: "edition") == reopened.pictureURL(picture))
    #expect(NSImage(contentsOf: reopened.pictureURL(picture)) != nil)
    try reopened.remove(picture, edition: "edition")
    #expect(reopened.selectedArtwork(for: "edition") == nil)
    #expect(!fm.fileExists(atPath: reopened.pictureURL(picture).path))
}

@Test func libraryBackupRejectsUnexpectedAndTraversingPaths() throws {
    let library = Data(#"{"tracks":[],"playlists":[],"unchecked":[]}"#.utf8)
    let valid = LibraryBackup(version: 1, created: Date(), files: ["library.json": library], preferences: [:])
    try valid.validate()
    for path in ["../library.json", "Collection/../../escape", "/Collection/file", "Collection//file", "lastfm-queue.json"] {
        let archive = LibraryBackup(version: 1, created: Date(), files: ["library.json": library, path: Data()], preferences: [:])
        #expect(throws: (any Error).self) { try archive.validate() }
    }
    let credentials = LibraryBackup(version: 1, created: Date(), files: ["library.json": library],
                                    preferences: ["lastfm.session": Data()])
    #expect(throws: (any Error).self) { try credentials.validate() }
    let roundtrip = try JSONDecoder().decode(LibraryBackup.self, from: JSONEncoder().encode(valid))
    #expect(roundtrip.files == valid.files)
}
