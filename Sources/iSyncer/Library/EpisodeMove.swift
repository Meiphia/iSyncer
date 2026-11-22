import ClassicSync
import Foundation

struct EpisodeMove {
    let source: URL
    let destination: URL

    /// Episode-specific sidecars use the same filename stem. Shared season or show artwork stays put.
    private func files() throws -> [(from: URL, to: URL)] {
        let folder = source.deletingLastPathComponent()
        let target = destination.deletingLastPathComponent()
        let fromStem = source.deletingPathExtension().lastPathComponent
        let toStem = destination.deletingPathExtension().lastPathComponent
        let artwork = ["jpg", "jpeg", "png"]
        let subtitles = ["srt", "ass", "ssa", "vtt", "sub", "idx"]
        let siblings = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let sidecars = siblings.compactMap { url -> (URL, URL)? in
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent
            let image = artwork.contains(ext) && [fromStem, fromStem + "-thumb", fromStem + "-poster"].contains(stem)
            let text = stem == fromStem && ext == "nfo"
            let subtitle = subtitles.contains(ext) && (stem == fromStem || stem.hasPrefix(fromStem + "."))
            guard image || text || subtitle,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, target.appendingPathComponent(toStem + name.dropFirst(fromStem.count)))
        }
        return [(source, destination)] + sidecars
    }

    func perform(in root: URL, saveMetadata: () throws -> Void) throws {
        try Self.perform([self], in: root, saveMetadata: saveMetadata)
    }

    static func checkedFiles(_ moves: [Self], in root: URL, additionalRoots: [URL] = []) throws -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        let roots = ([root] + additionalRoots).map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let files = try moves.flatMap { move in
            let source = try move.source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let folder = move.destination.deletingLastPathComponent()
            let paths = [move.source, folder.deletingLastPathComponent(), folder]
            guard source.isRegularFile == true, source.isSymbolicLink != true,
                  roots.contains(where: { base in
                      paths.allSatisfy { $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") }
                  }) else {
                throw SyncError("The episode and its destination must be inside the media library.")
            }
            return try move.files()
        }
        func key(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
        let sourceKeys = Set(files.map { key($0.from) })
        let exactSources = Set(files.map { $0.from.standardizedFileURL.path })
        guard sourceKeys.count == files.count, Set(files.map { key($0.to) }).count == files.count else {
            throw SyncError("Two episode files or sidecars would use the same path.")
        }
        for (_, to) in files where !exactSources.contains(to.standardizedFileURL.path) {
            if (try? fm.attributesOfItem(atPath: to.path)) != nil {
                throw SyncError("A file already exists at \(to.lastPathComponent). Choose a different season or episode.")
            }
        }
        return files
    }

    static func perform(_ moves: [Self], in root: URL, additionalRoots: [URL] = [], saveMetadata: () throws -> Void) throws {
        let fm = FileManager.default
        let files = try checkedFiles(moves, in: root, additionalRoots: additionalRoots)
        var staged: [(from: URL, temp: URL, to: URL)] = []
        var placed = 0
        do {
            // Stage every source first so swaps and offsets can use each other's old paths.
            for (from, to) in files {
                let temp = from.deletingLastPathComponent().appendingPathComponent(".isyncer-move-\(UUID())")
                try fm.moveItem(at: from, to: temp)
                staged.append((from, temp, to))
            }
            for (_, temp, to) in staged {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: temp, to: to)
                placed += 1
            }
            try saveMetadata()
        } catch {
            var failed: [String] = []
            for (_, temp, to) in staged.prefix(placed).reversed() {
                do { try fm.moveItem(at: to, to: temp) }
                catch { failed.append(to.path) }
            }
            for (from, temp, _) in staged.reversed() where fm.fileExists(atPath: temp.path) {
                do { try fm.moveItem(at: temp, to: from) }
                catch { failed.append(temp.path) }
            }
            if !failed.isEmpty {
                throw SyncError("The move could not be completed or fully reversed. Files remain at: \(failed.joined(separator: ", ")).")
            }
            throw error
        }
    }
}

struct PlannedEpisodeMove {
    let previous: VideoItem
    let updated: VideoItem
    let files: EpisodeMove
}

struct EpisodeNumberEdit {
    let video: VideoItem
    let season: Int
    let episode: Int

    static func plan(_ edits: [Self], videos: [VideoItem], root: URL, additionalRoots: [URL] = []) throws -> [PlannedEpisodeMove] {
        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        var moves: [PlannedEpisodeMove] = []
        for edit in edits {
            guard let video = byID[edit.video.id], video.size == edit.video.size, video.modified == edit.video.modified else {
                throw SyncError("An episode changed. Rescan the library and try again.")
            }
            if video.season == edit.season && video.episode == edit.episode &&
                (VideoScanner.folderSeason(for: video) ?? video.season) == edit.season { continue }
            guard let path = VideoScanner.episodePath(for: video, season: edit.season, episode: edit.episode, at: root) else {
                throw SyncError("Choose a season from 0 to 99 and an episode from 1 to 999.")
            }
            guard path != video.id else { continue }
            let updated = VideoScanner.parse(path, size: video.size, modified: video.modified)
            guard updated.kind == .tv, updated.show == video.show, updated.season == edit.season, updated.episode == edit.episode else {
                throw SyncError("This episode’s folder layout could not be renumbered safely.")
            }
            let files = EpisodeMove(source: root.appendingLibraryPath(video.id), destination: root.appendingLibraryPath(path))
            moves.append(PlannedEpisodeMove(previous: video, updated: updated, files: files))
        }
        let sourceIDs = Set(moves.map { $0.previous.id })
        var numbers = Set(videos.filter { $0.kind == .tv && !sourceIDs.contains($0.id) }.map(\.classicTVKey))
        for move in moves {
            guard numbers.insert(move.updated.classicTVKey).inserted else {
                throw SyncError("\(move.updated.show) already has S\(move.updated.season)E\(move.updated.episode) in this plan.")
            }
        }
        _ = try EpisodeMove.checkedFiles(moves.map(\.files), in: root, additionalRoots: additionalRoots)
        return moves
    }
}
