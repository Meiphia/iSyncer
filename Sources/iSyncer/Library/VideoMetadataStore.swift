import ClassicSync
import CryptoKit
import Foundation

/// Keeps edits in Application Support, including for video files on read-only volumes.
struct VideoMetadataStore: Sendable {
    let folder: URL

    private var fingerprints: URL { folder.appendingPathComponent("By Content", isDirectory: true) }

    func legacyLocation(for url: URL) -> URL {
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key + ".plist")
    }

    func read(_ location: URL) -> VideoMetadataEdit? {
        guard let data = try? Data(contentsOf: location) else { return nil }
        return try? PropertyListDecoder().decode(VideoMetadataEdit.self, from: data)
    }

    func save(_ edit: VideoMetadataEdit, at location: URL) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(edit).write(to: location, options: .atomic)
    }

    func contentLocation(for url: URL, size: Int64) throws -> URL {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard size >= 0, try file.seekToEnd() == UInt64(size) else {
            throw SyncError("The video changed while saving its metadata. Rescan the library and try again.")
        }
        // Hash short blocks distributed across large videos. Small files are read in full.
        let block: UInt64 = 64 * 1024
        let length = UInt64(size)
        let bufferLength = block * 16
        let offsets = length <= bufferLength ? [UInt64(0)] :
            (0..<16).map { (length - block) / 15 * UInt64($0) }
        let count = Int(length <= bufferLength ? length : block)
        var hash = SHA256()
        for offset in offsets {
            try file.seek(toOffset: offset)
            let bytes = try file.read(upToCount: count) ?? Data()
            guard bytes.count == count else { throw SyncError("The video changed while reading its metadata.") }
            hash.update(data: bytes)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return fingerprints.appendingPathComponent("\(size)-\(digest).plist")
    }

    /// Resolves legacy path-based edits and finds edits for files that moved between scans.
    func resolve(_ items: [VideoItem], root: URL, previous: [VideoItem] = [], legacyRoots: [URL] = []) -> [String: URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: fingerprints.path)) ?? []
        let editedSizes = Set(names.compactMap { $0.split(separator: "-").first.flatMap { Int64($0) } })
        struct FileSignature: Hashable {
            let size: Int64
            let modified: Double
            let name: String

            init(_ item: VideoItem) {
                size = item.size
                modified = item.modified
                name = (item.id as NSString).lastPathComponent
            }
        }
        let currentByPath = Dictionary(items.map { ($0.id, FileSignature($0)) }, uniquingKeysWith: { first, _ in first })
        let previousByPath = Dictionary(previous.map { ($0.id, FileSignature($0)) }, uniquingKeysWith: { first, _ in first })
        let moved = previous.filter { currentByPath[$0.id] != FileSignature($0) }
        let old = Dictionary(grouping: moved, by: FileSignature.init)
        let new = Dictionary(grouping: items.filter { old[FileSignature($0)] != nil }, by: FileSignature.init)
        var locations: [String: URL] = [:]
        for item in items {
            let url = root.appendingPathComponent(item.id)
            let currentLegacy = legacyLocation(for: url)
            let previousLegacy = legacyRoots.map { legacyLocation(for: $0.appendingPathComponent(item.id)) }
            let signature = FileSignature(item)
            let movedLegacy: [URL]
            if let candidates = old[signature], candidates.count == 1, new[signature]?.count == 1 {
                movedLegacy = ([root] + legacyRoots).map { legacyLocation(for: $0.appendingPathComponent(candidates[0].id)) }
            } else {
                movedLegacy = []
            }
            let oldSignature = previousByPath[item.id]
            let directLegacy = oldSignature == nil || oldSignature == signature ? [currentLegacy] + previousLegacy : []
            let legacy = (directLegacy + movedLegacy).first { fm.fileExists(atPath: $0.path) }
            guard legacy != nil || editedSizes.contains(item.size) else { continue }
            if let content = try? contentLocation(for: url, size: item.size) {
                if fm.fileExists(atPath: content.path) {
                    locations[item.id] = content
                    continue
                }
                if let legacy, let edit = read(legacy), (try? save(edit, at: content)) != nil {
                    // Retire the path key so a different file placed there cannot inherit this edit.
                    try? fm.removeItem(at: legacy)
                    locations[item.id] = content
                    continue
                }
            }
            locations[item.id] = legacy
        }
        return locations
    }
}
