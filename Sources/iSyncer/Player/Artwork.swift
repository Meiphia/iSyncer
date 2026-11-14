import AppKit
import ClassicSync

/// Album art: embedded picture first, then common folder images. Cached per album folder.
@MainActor
final class ArtworkLoader: ObservableObject {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSString, NSImage>()
    @Published private(set) var podcastRevision = 0

    nonisolated static let folderImageNames = ["cover", "folder", "front", "albumart", "album", "art"]
    nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "webp"]

    func image(for track: Track) async -> NSImage? {
        guard let url = LibraryStore.shared.url(for: track) else { return nil }
        let key = cacheKey(for: track, url: url)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        let isPodcast = track.podcastShow != nil
        let isAudiobook = track.audiobookTitle != nil
        let data: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
            if isPodcast || isAudiobook, let art = MediaArtwork.externalData(at: url) { return art }
            if let art = TagReader.read(url: url, wantArtwork: true)?.artwork { return art }
            if let folderImage = Self.folderImage(in: url.deletingLastPathComponent()) {
                return try? Data(contentsOf: folderImage)
            }
            return nil
        }.value

        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Drops the cached picture for a song's album (after Get Info changed its artwork).
    func forget(_ track: Track) {
        guard let url = LibraryStore.shared.url(for: track) else { return }
        cache.removeObject(forKey: cacheKey(for: track, url: url) as NSString)
    }

    func podcastArtworkChanged() {
        podcastRevision += 1
    }

    private func cacheKey(for track: Track, url: URL) -> String {
        if track.podcastShow != nil { return "\(url.path)|podcast|\(podcastRevision)" }
        return url.deletingLastPathComponent().path + "|" + track.album
    }

    /// cover.jpg / folder.jpg / … or, failing that, the only image in the folder.
    nonisolated static func folderImage(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        for name in folderImageNames {
            if let hit = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return hit
            }
        }
        return images.count == 1 ? images[0] : nil
    }
}
