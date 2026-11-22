import Foundation

struct ScannedPlaylist: Sendable {
    let relativePath: String
    let name: String
    let trackIDs: [String]
}

struct ScanResult: Sendable {
    var tracks: [Track]
    var playlists: [ScannedPlaylist]
    var added = 0
    var updated = 0
    var removed = 0
}

/// Walks the library folder. Unchanged files (same size + mtime) reuse cached tags; new or
/// changed files are parsed in parallel.
enum Scanner {
    static func scan(root: URL, existing: [String: Track], aliases: [String: String] = [:],
                     absoluteIDs: Bool = false, progress: @escaping @Sendable (Int, Int) -> Void) -> ScanResult {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        struct Candidate {
            let id: String
            let url: URL
            let size: Int64
            let modified: Double
        }

        var candidates: [Candidate] = []
        var playlistFiles: [URL] = []

        if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                if ConversionCache.isManagedFolder(url) {
                    e.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let isAudio = TagReader.audioExtensions.contains(ext)
                let isPlaylist = TagReader.playlistExtensions.contains(ext)
                guard isAudio || isPlaylist else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                if isPlaylist { playlistFiles.append(url); continue }
                guard let relative = relativePath(of: url, rootPath: rootPath),
                      !VideoScanner.isVideo(root.lastPathComponent + "/" + relative) else { continue }
                let id = absoluteIDs ? url.standardizedFileURL.path : relative
                candidates.append(Candidate(
                    id: id,
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }

        var result = ScanResult(tracks: [], playlists: [])
        var fresh: [Track] = []
        var toParse: [Candidate] = []
        for c in candidates {
            if let old = existing[c.id], old.size == c.size, old.modified == c.modified {
                fresh.append(old)
            } else {
                toParse.append(c)
            }
        }

        let total = toParse.count
        progress(0, total)
        let now = Date().timeIntervalSince1970
        let lock = NSLock()
        var parsed = [Track?](repeating: nil, count: total)
        var done = 0

        DispatchQueue.concurrentPerform(iterations: total) { i in
            let c = toParse[i]
            let info = TagReader.read(url: c.url) ?? fallbackInfo(for: c.url)
            var track: Track
            if var old = existing[c.id] {
                old.update(from: info, size: c.size, modified: c.modified)
                track = old
            } else {
                track = Track(id: c.id, size: c.size, modified: c.modified, info: info, dateAdded: now)
            }
            lock.lock()
            parsed[i] = track
            done += 1
            let d = done
            lock.unlock()
            if d % 250 == 0 || d == total { progress(d, total) }
        }

        for t in parsed.compactMap({ $0 }) {
            if existing[t.id] == nil { result.added += 1 } else { result.updated += 1 }
            fresh.append(t)
        }
        let currentIDs = Set(candidates.map(\.id))
        result.removed = existing.keys.filter { !currentIDs.contains($0) }.count
        result.tracks = sortCanonical(fresh)

        // Playlists found in the library folder.
        var idsByNormalized = Dictionary(fresh.map { (root.appendingLibraryPath($0.id).standardizedFileURL.path.precomposedStringWithCanonicalMapping, $0.id) },
                                         uniquingKeysWith: { a, _ in a })
        for (old, new) in aliases where currentIDs.contains(new) {
            let key = root.appendingLibraryPath(old).standardizedFileURL.path.precomposedStringWithCanonicalMapping
            if idsByNormalized[key] == nil { idsByNormalized[key] = new }
        }
        for url in playlistFiles.sorted(by: { $0.path < $1.path }) {
            guard let rel = relativePath(of: url, rootPath: rootPath) else { continue }
            let ids = parseM3U(url, lookup: idsByNormalized)
            result.playlists.append(ScannedPlaylist(
                relativePath: absoluteIDs ? url.standardizedFileURL.path : rel,
                name: url.deletingPathExtension().lastPathComponent,
                trackIDs: ids))
        }
        return result
    }

    static func sortCanonical(_ tracks: [Track]) -> [Track] {
        tracks.sorted { a, b in
            let aa = a.displayAlbumArtist, ba = b.displayAlbumArtist
            if aa != ba { return aa.localizedStandardCompare(ba) == .orderedAscending }
            if a.album != b.album { return a.album.localizedStandardCompare(b.album) == .orderedAscending }
            if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
            if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    static func relativePath(of url: URL, rootPath: String) -> String? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func fallbackInfo(for url: URL) -> TagInfo {
        var info = TagInfo()
        info.title = url.deletingPathExtension().lastPathComponent
        info.codec = url.pathExtension.uppercased()
        return info
    }

    static func parseM3U(_ url: URL, lookup: [String: String]) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let dir = url.deletingLastPathComponent()
        var ids: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            line = line.replacingOccurrences(of: "\\", with: "/")
            let resolved: URL
            if line.hasPrefix("file://"), let u = URL(string: line) {
                resolved = u
            } else if line.hasPrefix("/") {
                resolved = URL(fileURLWithPath: line)
            } else {
                resolved = dir.appendingPathComponent(line)
            }
            guard let id = lookup[resolved.standardizedFileURL.path.precomposedStringWithCanonicalMapping] else { continue }
            ids.append(id)
        }
        return ids
    }
}
