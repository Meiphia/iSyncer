import Foundation

extension URL {
    /// Existing library IDs stay relative to their original root. Additional folders use
    /// absolute IDs, so identical relative paths in different sources remain distinct.
    func appendingLibraryPath(_ id: String) -> URL {
        id.hasPrefix("/") ? URL(fileURLWithPath: id) : appendingPathComponent(id)
    }
}

enum LibraryFolders {
    static func contains(_ folder: URL, _ url: URL) -> Bool {
        let base = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    static func adding(_ urls: [URL], to existing: [URL]) throws -> [URL] {
        var result = existing
        for url in urls {
            let folder = url.resolvingSymlinksInPath().standardizedFileURL
            guard folder.path != "/", try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  FileManager.default.isReadableFile(atPath: folder.path), !ConversionCache.isManagedFolder(folder) else {
                throw ShellError(message: "Choose a readable media folder outside iSyncer’s conversion cache.")
            }
            if result.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == folder.path }) { continue }
            guard !result.contains(where: {
                let prior = $0.resolvingSymlinksInPath().standardizedFileURL
                return contains(prior, folder) || contains(folder, prior)
            }) else {
                throw ShellError(message: "This folder overlaps a folder already in the library. Add separate folders to avoid scanning files twice.")
            }
            result.append(folder)
        }
        return result
    }

    static func available(_ folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
            FileManager.default.isReadableFile(atPath: folder.path)
    }

    struct Result {
        var scan: ScanResult
        var unavailable: Set<String>
    }

    static func scan(_ folders: [URL], anchor: URL, existing: [String: Track], aliases: [String: String],
                     progress: @escaping @Sendable (Int, Int) -> Void) -> Result {
        var result = ScanResult(tracks: [], playlists: [])
        var unavailable = Set<String>()
        for folder in folders {
            let prior = existing.filter { contains(folder, anchor.appendingLibraryPath($0.key)) }
            guard available(folder) else {
                result.tracks += prior.values
                unavailable.formUnion(prior.keys)
                continue
            }
            let scanned = Scanner.scan(root: folder, existing: prior, aliases: aliases,
                                       absoluteIDs: folder.path != anchor.path, progress: progress)
            result.tracks += scanned.tracks
            result.playlists += scanned.playlists
            result.added += scanned.added
            result.updated += scanned.updated
            result.removed += scanned.removed
        }
        var lookup = Dictionary(result.tracks.map {
            (anchor.appendingLibraryPath($0.id).standardizedFileURL.path.precomposedStringWithCanonicalMapping, $0.id)
        }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(result.tracks.map(\.id))
        for (old, new) in aliases where currentIDs.contains(new) {
            let path = anchor.appendingLibraryPath(old).standardizedFileURL.path.precomposedStringWithCanonicalMapping
            if lookup[path] == nil { lookup[path] = new }
        }
        result.playlists = result.playlists.map { playlist in
            ScannedPlaylist(relativePath: playlist.relativePath, name: playlist.name,
                            trackIDs: Scanner.parseM3U(anchor.appendingLibraryPath(playlist.relativePath), lookup: lookup))
        }
        result.tracks = Scanner.sortCanonical(result.tracks)
        return Result(scan: result, unavailable: unavailable)
    }
}
