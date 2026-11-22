import AppKit
import CryptoKit
import Foundation

/// User curation stored alongside the library index.
@MainActor
final class LibraryCollection: ObservableObject {
    static let shared = LibraryCollection()
    struct Picture: Codable, Identifiable, Equatable {
        let id: UUID
        var label: String
        let file: String
    }
    struct Gallery: Codable {
        var pictures: [Picture] = []
        var selected: UUID?
    }
    struct Saved: Codable {
        var aliases: [String: String] = [:]
        var galleries: [String: Gallery] = [:]
    }

    @Published private(set) var revision = 0
    private(set) var saved: Saved
    let folder: URL
    var indexURL: URL { folder.appending(path: "collection.json") }

    init(folder suppliedFolder: URL? = nil) {
        let folder = suppliedFolder ?? LibraryStore.supportFolder.appending(path: "Collection", directoryHint: .isDirectory)
        self.folder = folder
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: folder.appending(path: "collection.json")))) ?? Saved()
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    func artist(_ name: String) -> String { saved.aliases[Self.normalized(name)] ?? name }

    func setArtist(_ canonical: String, aliases: [String]) throws {
        let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { throw ShellError(message: "Enter an artist name.") }
        let existing = artist(canonical)
        let group = Set(([canonical, existing] + aliases).map(Self.normalized)).subtracting([""])
        var next = saved
        // Merge selected groups and flatten mappings so aliases cannot form cycles.
        let owners = Set(group.compactMap { saved.aliases[$0] }.map(Self.normalized)).union(group)
        for (key, value) in next.aliases where owners.contains(Self.normalized(value)) {
            next.aliases[key] = canonical
        }
        for alias in group { next.aliases[alias] = canonical }
        try commit(next)
    }

    func unlink(_ alias: String) throws {
        var next = saved
        next.aliases.removeValue(forKey: Self.normalized(alias))
        try commit(next)
    }

    func gallery(for edition: String) -> Gallery { saved.galleries[edition] ?? Gallery() }

    func pictureURL(_ picture: Picture) -> URL { folder.appending(path: picture.file) }

    func selectedArtwork(for edition: String) -> URL? {
        let gallery = gallery(for: edition)
        return gallery.pictures.first { $0.id == gallery.selected }.map(pictureURL)
    }

    func addPicture(_ url: URL, label: String, edition: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 8_388_608,
              let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]),
              png.count <= 8_388_608 else {
            throw ShellError(message: "Choose an image up to 8 MB.")
        }
        let id = UUID()
        let picture = Picture(id: id, label: label.isEmpty ? url.deletingPathExtension().lastPathComponent : label,
                              file: id.uuidString + ".png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: pictureURL(picture), options: .atomic)
        var next = saved
        var gallery = next.galleries[edition] ?? Gallery()
        gallery.pictures.append(picture)
        next.galleries[edition] = gallery
        do { try commit(next) }
        catch { try? FileManager.default.removeItem(at: pictureURL(picture)); throw error }
    }

    func select(_ picture: UUID?, edition: String) throws {
        var next = saved
        var gallery = next.galleries[edition] ?? Gallery()
        gallery.selected = picture
        next.galleries[edition] = gallery
        try commit(next)
    }

    func remove(_ picture: Picture, edition: String) throws {
        var next = saved
        var gallery = next.galleries[edition] ?? Gallery()
        gallery.pictures.removeAll { $0.id == picture.id }
        if gallery.selected == picture.id { gallery.selected = nil }
        next.galleries[edition] = gallery
        try commit(next)
        try? FileManager.default.removeItem(at: pictureURL(picture))
    }

    private func commit(_ next: Saved) throws {
        guard !DeviceManager.shared.busy else {
            throw ShellError(message: "Wait for the current iPod operation to finish before changing library artwork or artist links.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: indexURL, options: .atomic)
        saved = next
        revision += 1
        ArtworkLoader.shared.podcastArtworkChanged()
        DeviceManager.shared.collectionDidChange()
    }

    func reload() {
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: indexURL))) ?? Saved()
        revision += 1
        ArtworkLoader.shared.podcastArtworkChanged()
    }
}
