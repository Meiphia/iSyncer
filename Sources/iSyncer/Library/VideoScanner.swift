import Foundation

/// Finds video files and works out show/season/episode or movie title/year from the usual
/// media-server naming (Jellyfin/Plex/Kodi style) for the library and iPod metadata.
enum VideoScanner {
    static let extensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "flv"]

    private static let tvFolders: Set<String> = ["tv", "tv shows", "tvshows", "tv-shows", "series", "shows"]
    private static let movieFolders: Set<String> = ["movies", "movie", "films", "film"]
    private static let videoContainers: Set<String> = ["videos", "video", "tv", "tv shows", "tvshows", "tv-shows",
                                                       "series", "shows", "movies", "movie", "films", "film"]

    /// The one rule for music vs video in the media library. Video-only containers are always
    /// video; .mp4 (often music too) counts as video only inside a TV/Movies/Videos folder.
    static func isVideo(_ relativePath: String) -> Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { return false }
        if ext != "mp4" { return true }
        return relativePath.split(separator: "/").dropLast().contains { videoContainers.contains($0.lowercased()) }
    }

    static func scan(root: URL, absoluteIDs: Bool = false) -> [VideoItem] {
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [VideoItem] = []
        for case let url as URL in e {
            if ConversionCache.isManagedFolder(url) {
                e.skipDescendants()
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(path.dropFirst(rootPath.count + 1))
            guard isVideo(root.lastPathComponent + "/" + rel), let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            var item = parse(root.lastPathComponent + "/" + rel, size: Int64(v.fileSize ?? 0),
                             modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            item.id = absoluteIDs ? path : rel
            out.append(item)
        }
        return out.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue > b.kind.rawValue }   // tv, other, movie
            if a.show != b.show { return a.show.localizedStandardCompare(b.show) == .orderedAscending }
            if a.season != b.season { return a.season < b.season }
            if a.episode != b.episode { return a.episode < b.episode }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    static func parse(_ rel: String, size: Int64, modified: Double) -> VideoItem {
        let comps = rel.split(separator: "/").map(String.init)
        let file = comps.last ?? rel
        let base = (file as NSString).deletingPathExtension
        let folders = Array(comps.dropLast())
        let lower = folders.map { $0.lowercased() }

        var item = VideoItem(id: rel, size: size, modified: modified, kind: .other,
                             show: "", season: 0, episode: 0, title: clean(base), year: 0)

        let se = seasonEpisode(in: base)
        let tvIndex = lower.firstIndex { tvFolders.contains($0) }

        if tvIndex != nil || se != nil {
            item.kind = .tv
            // Show: folder right below "TV", else the folder above "Season N", else text before SxxEyy.
            var showFolderIndex: Int?
            if let i = tvIndex, i + 1 < folders.count { showFolderIndex = i + 1 }
            if showFolderIndex == nil, let si = folders.lastIndex(where: { seasonNumber($0) != nil }), si > 0 {
                showFolderIndex = si - 1
            }
            if let i = showFolderIndex {
                item.show = clean(folders[i])
            } else if let se, se.range.lowerBound > base.startIndex {
                item.show = clean(String(base[..<se.range.lowerBound]))
            } else if let parent = folders.last {
                item.show = clean(parent)
            }
            item.season = se?.season ?? folders.compactMap(seasonNumber).last ?? 1
            if let se {
                item.episode = se.episode
                item.title = clean(String(base[se.range.upperBound...]))
            } else if let (n, rest) = leadingNumber(base) {
                item.episode = n
                item.title = clean(rest)
            }
            if item.title.isEmpty { item.title = item.episode > 0 ? "Episode \(item.episode)" : clean(base) }
            return item
        }

        if let mi = lower.firstIndex(where: { movieFolders.contains($0) }) {
            item.kind = .movie
            let source = mi + 1 < folders.count ? folders[mi + 1] : base
            let (title, year) = titleAndYear(source)
            item.title = title.isEmpty ? clean(base) : title
            item.year = year
            if item.year == 0 { item.year = titleAndYear(base).1 }
        }
        return item
    }

    /// A scanner-readable destination for correcting an episode's numbering.
    static func episodePath(for video: VideoItem, season: Int, episode: Int, at root: URL) -> String? {
        guard video.kind == .tv, !video.show.isEmpty,
              (0...99).contains(season), (1...999).contains(episode) else { return nil }
        let parts = video.id.split(separator: "/").map(String.init)
        guard let filename = parts.last else { return nil }
        let folders = Array(parts.dropLast())
        let showFolders: [String]
        if let tv = folders.firstIndex(where: { tvFolders.contains($0.lowercased()) }) {
            showFolders = tv + 1 < folders.count ? Array(folders.prefix(tv + 2)) : folders + [video.show]
        } else if let index = folders.lastIndex(where: { seasonNumber($0) != nil }), index > 0 {
            showFolders = Array(folders.prefix(index))
        } else if let parent = folders.last, clean(parent) == video.show {
            showFolders = folders
        } else {
            showFolders = folders + [video.show]
        }
        guard showFolders.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let currentSeasonFolder = folders.dropFirst(showFolders.count).first
        let showURL = root.appendingLibraryPath((video.id.hasPrefix("/") ? "/" : "") + showFolders.joined(separator: "/"))
        let seasonFolder: String
        if let currentSeasonFolder, seasonNumber(currentSeasonFolder) == season {
            seasonFolder = currentSeasonFolder
        } else {
            let existing = try? FileManager.default.contentsOfDirectory(at: showURL, includingPropertiesForKeys: [.isDirectoryKey])
            seasonFolder = existing?.sorted { $0.lastPathComponent < $1.lastPathComponent }.first {
                seasonNumber($0.lastPathComponent) == season &&
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }?.lastPathComponent ?? "Season \(season)"
        }
        let basename = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let marker = String(format: "S%02dE%02d", season, episode)
        let renamed: String
        if let match = seasonEpisode(in: basename) {
            renamed = basename.replacingCharacters(in: match.range, with: marker)
        } else {
            let suffix = leadingNumber(basename).map { clean($0.1) } ?? basename
            renamed = suffix.isEmpty ? marker : "\(marker) - \(suffix)"
        }
        let targetFolders = season == video.season && seasonNumber(currentSeasonFolder ?? "") == season
            ? folders : showFolders + [seasonFolder]
        return (video.id.hasPrefix("/") ? "/" : "") + (targetFolders + ["\(renamed).\(ext)"]).joined(separator: "/")
    }

    // MARK: Pattern helpers

    /// S01E02 / s1e2 / 1x02 → (season, episode, range of the marker)
    private static func seasonEpisode(in s: String) -> (season: Int, episode: Int, range: Range<String.Index>)? {
        for pattern in [#"[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})"#, #"\b(\d{1,2})x(\d{2,3})\b"#] {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range, in: s), let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
                  let season = Int(s[r1]), let episode = Int(s[r2]) else { continue }
            return (season, episode, r)
        }
        return nil
    }

    static func folderSeason(for video: VideoItem) -> Int? {
        video.id.split(separator: "/").dropLast().reversed().compactMap { seasonNumber(String($0)) }.first
    }

    private static func seasonNumber(_ folder: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"^(?:season|series|s)[ ._-]*(\d{1,2})$"#, options: .caseInsensitive),
              let m = re.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)),
              let r = Range(m.range(at: 1), in: folder) else { return nil }
        return Int(folder[r])
    }

    /// "03. Title" / "03 - Title" / "03 Title" → (3, "Title")
    private static func leadingNumber(_ s: String) -> (Int, String)? {
        guard let re = try? NSRegularExpression(pattern: #"^(\d{1,3})[ ._-]+(.*)$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let n = Int(s[r1]) else { return nil }
        return (n, String(s[r2]))
    }

    /// "Title (1999)" / "Title.1999.1080p" → ("Title", 1999)
    private static func titleAndYear(_ s: String) -> (String, Int) {
        guard let re = try? NSRegularExpression(pattern: #"^(.*?)[ ._(\[]+((?:19|20)\d{2})(?:[)\]]|[ ._]|$)"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s) else {
            return (clean(s), 0)
        }
        return (clean(String(s[r1])), Int(s[r2]) ?? 0)
    }

    /// Dots/underscores to spaces, trims separators, drops release-group junk in brackets.
    private static func clean(_ s: String) -> String {
        var t = s
        if !t.contains(" ") { t = t.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -._–"))
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }
}
