import AppKit
import ClassicSync
import CryptoKit
import Foundation

struct PodcastEpisode: Identifiable, Sendable {
    let title: String
    let enclosure: URL
    let fileExtension: String
    var image: URL? = nil
    var summary: String? = nil
    var publishedAt: Date? = nil
    var id: URL { enclosure }
}

struct PodcastFeed: Sendable {
    let title: String
    let episodes: [PodcastEpisode]
    let url: URL
    let image: URL?
    let author: String?

    var newestFirst: [PodcastEpisode] {
        var seen = Set<URL>()
        return episodes.enumerated().sorted {
            let first = $0.element.publishedAt ?? .distantPast
            let second = $1.element.publishedAt ?? .distantPast
            return first == second ? $0.offset < $1.offset : first > second
        }.map(\.element).filter { seen.insert($0.id).inserted }
    }

    static func load(_ input: String) async throws -> PodcastFeed {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), isWebURL(url) else {
            throw SyncError("Enter an HTTP or HTTPS RSS feed URL.")
        }
        let request = URLRequest(url: url, timeoutInterval: 12)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try check(response)
        let limit = 5 * 1024 * 1024
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw SyncError("The RSS feed exceeds 5 MB.") }
            data.append(byte)
        }
        return try parse(data, relativeTo: response.url ?? url)
    }

    static func parse(_ data: Data, relativeTo url: URL) throws -> PodcastFeed {
        let parser = XMLParser(data: data)
        let delegate = FeedParser(baseURL: url)
        parser.delegate = delegate
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), delegate.isRSS else { throw SyncError("This URL did not return a valid RSS feed.") }
        let episodes = delegate.episodes
        guard !episodes.isEmpty else { throw SyncError("The feed has no supported MP3 or AAC episodes.") }
        return PodcastFeed(title: delegate.title.isEmpty ? url.host ?? "Podcast" : delegate.title, episodes: episodes, url: url, image: delegate.image, author: delegate.author)
    }

    func destination(for episode: PodcastEpisode, in root: URL) -> URL {
        let folder = root.appending(path: "Podcasts", directoryHint: .isDirectory)
            .appending(path: PathRules.sanitize(title), directoryHint: .isDirectory)
        let key = SHA256.hash(data: Data(episode.enclosure.absoluteString.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        let name = PathRules.sanitize(episode.title, maxLength: 95)
        return folder.appending(path: "\(name) [\(key)].\(episode.fileExtension)")
    }

    func download(_ episode: PodcastEpisode, into root: URL) async throws {
        let destination = destination(for: episode, in: root)
        let folder = destination.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            let (download, response) = try await URLSession.shared.download(from: episode.enclosure)
            defer { try? fm.removeItem(at: download) }
            try Self.check(response)
            try await Self.importEpisode(download, to: destination, in: root)
        }
        let metadata = PodcastMetadata(feed: url.absoluteString, enclosure: episode.enclosure.absoluteString,
                                       title: episode.title, author: author, summary: episode.summary,
                                       publishedAt: episode.publishedAt ?? PodcastMetadata.load(for: destination)?.publishedAt)
        try JSONEncoder().encode(metadata).write(to: PodcastMetadata.sidecar(for: destination), options: .atomic)
        try Data(url.absoluteString.utf8).write(to: folder.appending(path: ".feed-url"), options: .atomic)
        if let image = episode.image {
            try? await Self.saveImage(image, at: destination.appendingPathExtension("cover"))
        }
        if let image {
            try? await Self.saveImage(image, at: folder.appending(path: "cover.jpg"))
        }

    }

    static func refreshReleaseDates(for urls: [URL]) async -> [URL: PodcastMetadata] {
        let pending = urls.compactMap { url -> (URL, PodcastMetadata)? in
            guard let metadata = PodcastMetadata.load(for: url), metadata.publishedAt == nil,
                  let feed = URL(string: metadata.feed), isWebURL(feed), feed.host != "isyncer.invalid" else { return nil }
            return (url, metadata)
        }
        return await withTaskGroup(of: [(URL, PodcastMetadata)].self) { tasks in
            for (feed, items) in Dictionary(grouping: pending, by: { $0.1.feed }) {
                tasks.addTask {
                    guard let rss = try? await load(feed) else { return [] }
                    let dates = Dictionary(uniqueKeysWithValues: rss.newestFirst.compactMap { episode in
                        episode.publishedAt.map { (episode.enclosure, $0) }
                    })
                    return items.compactMap { url, metadata in
                        guard let enclosure = URL(string: metadata.enclosure), let date = dates[enclosure] else { return nil }
                        var updated = metadata
                        updated.publishedAt = date
                        if PodcastMetadata.load(for: url) == metadata,
                           let data = try? JSONEncoder().encode(updated) {
                            try? data.write(to: PodcastMetadata.sidecar(for: url), options: .atomic)
                        }
                        return (url, updated)
                    }
                }
            }
            var updated: [URL: PodcastMetadata] = [:]
            for await items in tasks {
                for (url, metadata) in items { updated[url] = metadata }
            }
            return updated
        }
    }

    private static func saveImage(_ url: URL, at destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        try check(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { return }
            data.append(byte)
        }
        guard NSImage(data: data) != nil else { return }
        try data.write(to: destination, options: .atomic)
    }

    static func importEpisode(_ download: URL, to destination: URL, in root: URL) async throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try Task.checkCancellation()
        let scratch = fm.temporaryDirectory.appending(path: "iSyncer-podcast-\(UUID())", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let audio = scratch.appending(path: destination.lastPathComponent)
        try fm.copyItem(at: download, to: audio)
        let checked = try await LibraryScanner.scanFiles([audio])
        guard !checked.songs.isEmpty else { throw SyncError("The episode is not playable on the iPod Classic.") }
        try Task.checkCancellation()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SyncError("The media library folder is unavailable.")
        }
        // Stage on the destination volume so a failed copy cannot leave a partial episode.
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".\(UUID()).part")
        defer { try? fm.removeItem(at: partial) }
        try fm.copyItem(at: audio, to: partial)
        try Task.checkCancellation()
        do {
            try fm.moveItem(at: partial, to: destination)
        } catch {
            guard fm.fileExists(atPath: destination.path) else { throw error }
        }
    }

    static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
            && url.user == nil && url.password == nil
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, let url = http.url, isWebURL(url),
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse).map { " (HTTP \($0.statusCode))" } ?? ""
            throw SyncError("The podcast server could not complete the request\(status).")
        }
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    let baseURL: URL
    var title = ""
    var episodes: [PodcastEpisode] = []
    var isRSS = false
    var image: URL?
    var author: String?
    private var episodeImage: URL?
    private var episodeSummary: String?
    private var episodeDate: Date?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()
    private var stack: [String] = []
    private var text = ""
    private var episodeTitle = ""
    private var enclosure: (URL, String)?
    private var seen: Set<URL> = []

    init(baseURL: URL) { self.baseURL = baseURL }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(element)
        switch stack {
        case ["rss", "channel"]:
            isRSS = true
        case ["rss", "channel", "item"]:
            episodeTitle = ""
            enclosure = nil
            episodeImage = nil
            episodeSummary = nil
            episodeDate = nil
        case ["rss", "channel", "itunes:image"]:
            image = webURL(attributes["href"]) ?? image
        case ["rss", "channel", "item", "itunes:image"]:
            episodeImage = webURL(attributes["href"])
        case ["rss", "channel", "title"], ["rss", "channel", "itunes:author"],
             ["rss", "channel", "image", "url"], ["rss", "channel", "item", "title"],
             ["rss", "channel", "item", "description"], ["rss", "channel", "item", "pubDate"]:
            text = ""
        case ["rss", "channel", "item", "enclosure"]:
            guard enclosure == nil, let path = attributes["url"],
                  let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
                  PodcastFeed.isWebURL(url) else { return }
            let type = attributes["type"]?.lowercased().split(separator: ";").first
            switch (url.pathExtension.lowercased(), type) {
            case ("mp3", _), (_, "audio/mpeg"), (_, "audio/mp3"): enclosure = (url, "mp3")
            case ("m4a", _), (_, "audio/mp4"), (_, "audio/x-m4a"): enclosure = (url, "m4a")
            default: break
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch stack {
        case ["rss", "channel", "title"], ["rss", "channel", "itunes:author"],
             ["rss", "channel", "image", "url"], ["rss", "channel", "item", "title"],
             ["rss", "channel", "item", "description"], ["rss", "channel", "item", "pubDate"]:
            text += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch stack {
        case ["rss", "channel", "title"]:
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case ["rss", "channel", "itunes:author"]:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            author = value.isEmpty ? nil : value
        case ["rss", "channel", "image", "url"]:
            image = image ?? webURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case ["rss", "channel", "item", "description"]:
            episodeSummary = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        case ["rss", "channel", "item", "title"]:
            episodeTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case ["rss", "channel", "item", "pubDate"]:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                           "EEE, d MMM yyyy HH:mm:ss z", "d MMM yyyy HH:mm:ss z",
                           "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z"] {
                dateFormatter.dateFormat = format
                if let date = dateFormatter.date(from: value) {
                    episodeDate = date
                    break
                }
            }
        case ["rss", "channel", "item"]:
            if let (url, ext) = enclosure, seen.insert(url).inserted {
                episodes.append(.init(title: episodeTitle.isEmpty ? "Episode" : episodeTitle, enclosure: url,
                                      fileExtension: ext, image: episodeImage, summary: episodeSummary, publishedAt: episodeDate))
            }
        default: break
        }
        _ = stack.popLast()
    }

    private func webURL(_ path: String?) -> URL? {
        guard let path, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              PodcastFeed.isWebURL(url) else { return nil }
        return url
    }

}
