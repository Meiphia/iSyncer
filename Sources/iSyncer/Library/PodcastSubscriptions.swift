import Foundation
import ClassicSync

@MainActor
final class PodcastSubscriptions: ObservableObject {
    static let shared = PodcastSubscriptions()

    struct Subscription: Codable, Identifiable {
        let id: URL
        let title: String
        var seen: Set<URL>
        var automaticDownloads: Bool? = nil
        var downloadLimit: Int? = nil

        var show: String { PathRules.sanitize(title) }
    }

    @Published private(set) var shows: [Subscription] = {
        guard let data = UserDefaults.standard.data(forKey: "podcastSubscriptions") else { return [] }
        return (try? JSONDecoder().decode([Subscription].self, from: data)) ?? []
    }()

    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    @Published private(set) var status = ""
    private var queuedFeeds: [PodcastFeed] = []
    private var timer: Task<Void, Never>?

    func start(library: LibraryStore) {
        guard timer == nil else { return }
        timer = Task {
            while !Task.isCancelled {
                await refresh(library)
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    func follow(_ feed: PodcastFeed, library: LibraryStore) {
        guard !shows.contains(where: { $0.id == feed.url }) else { return }
        // Download the newest episode on follow. Treat the back catalog as seen.
        let ordered = feed.newestFirst
        shows.append(.init(id: feed.url, title: feed.title, seen: Set(ordered.dropFirst().map(\.id))))
        save()
        Task { await refresh(library, feed: feed) }
    }

    func unfollow(_ url: URL) {
        shows.removeAll { $0.id == url }
        if shows.isEmpty { status = "" }
        save()
    }

    func reload() {
        shows = UserDefaults.standard.data(forKey: "podcastSubscriptions").flatMap {
            try? JSONDecoder().decode([Subscription].self, from: $0)
        } ?? []
    }

    func update(_ subscription: Subscription) {
        guard !checking, let index = shows.firstIndex(where: { $0.id == subscription.id }) else { return }
        shows[index].automaticDownloads = subscription.automaticDownloads
        shows[index].downloadLimit = subscription.downloadLimit
        save()
    }

    func stableFeed(_ feed: PodcastFeed, subscriptionID: URL? = nil) -> PodcastFeed {
        guard let subscription = shows.first(where: { $0.id == (subscriptionID ?? feed.url) }) else { return feed }
        return PodcastFeed(title: subscription.title, episodes: feed.episodes, url: subscription.id,
                           image: feed.image, author: feed.author)
    }

    struct Download {
        let url: URL
        let metadata: PodcastMetadata
        let date: Date
    }

    static func downloadWindow(episodes: [PodcastEpisode], existing: [Download], limit: Int) -> Set<String> {
        let feedDates = Dictionary(uniqueKeysWithValues: episodes.enumerated().map { ($0.element.enclosure.absoluteString, $0.offset) })
        let published = Dictionary(existing.compactMap { item in
            item.metadata.publishedAt.map { (item.metadata.enclosure, $0) }
        }, uniquingKeysWith: max)
        var dates = Dictionary(existing.map { ($0.metadata.enclosure, $0.metadata.publishedAt ?? $0.date) },
                               uniquingKeysWith: max)
        for episode in episodes {
            let key = episode.enclosure.absoluteString
            dates[key] = episode.publishedAt ?? published[key] ?? .distantPast
        }
        let ordered = dates.keys.sorted {
            if dates[$0] != dates[$1] { return (dates[$0] ?? .distantPast) > (dates[$1] ?? .distantPast) }
            return (feedDates[$0] ?? Int.max, $0) < (feedDates[$1] ?? Int.max, $1)
        }
        return Set(ordered.prefix(limit))
    }

    static func downloads(for feed: PodcastFeed, in root: URL) -> [Download] {
        let podcasts = root.appending(path: "Podcasts", directoryHint: .isDirectory)
        let folder = podcasts.appending(path: PathRules.sanitize(feed.title), directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard [podcasts, folder].allSatisfy({ url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                  options: .skipsHiddenFiles)) ?? []
        return files.compactMap { url in
            guard ["mp3", "m4a", "aac"].contains(url.pathExtension.lowercased()),
                  let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true, info.isSymbolicLink != true,
                  let metadata = PodcastMetadata.load(for: url), metadata.feed == feed.url.absoluteString else { return nil }
            return Download(url: url, metadata: metadata, date: info.contentModificationDate ?? .distantPast)
        }
    }

    func markSeen(_ episode: PodcastEpisode, in feed: PodcastFeed) {
        guard let index = shows.firstIndex(where: { $0.id == feed.url }) else { return }
        shows[index].seen.insert(episode.id)
        save()
    }

    func download(_ episode: PodcastEpisode, in feed: PodcastFeed, library: LibraryStore) async throws {
        guard !checking, !downloading, !DeviceManager.shared.busy, !library.isScanning,
              let root = library.downloadFolder else {
            throw SyncError("Wait for the current library or podcast operation to finish.")
        }
        downloading = true
        defer { downloading = false }
        try await feed.download(episode, into: root)
        guard library.downloadFolder == root else { return }
        markSeen(episode, in: feed)
        while library.isScanning || DeviceManager.shared.busy {
            try await Task.sleep(for: .milliseconds(250))
            guard library.downloadFolder == root else { return }
        }
        ArtworkLoader.shared.podcastArtworkChanged()
        library.scan()
    }

    func refresh(_ library: LibraryStore, feed: PodcastFeed? = nil) async {
        if checking {
            if let feed { queuedFeeds.append(feed) }
            return
        }
        guard !downloading, !DeviceManager.shared.busy, !shows.isEmpty, let root = library.downloadFolder,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
        checking = true
        status = "Checking followed shows…"
        defer {
            checking = false
            if !queuedFeeds.isEmpty {
                let next = queuedFeeds.removeFirst()
                Task { await refresh(library, feed: next) }
            }
        }
        var downloaded = 0
        var processed = false
        var failures = 0
        var trimmed = 0
        for subscription in shows where feed == nil || feed?.url == subscription.id {
            do {
                let current: PodcastFeed
                if let feed { current = feed }
                else { current = try await PodcastFeed.load(subscription.id.absoluteString) }
                let stable = stableFeed(current, subscriptionID: subscription.id)
                let ordered = stable.newestFirst
                let limit = subscription.downloadLimit.map { max(1, $0) }
                let downloads = library.libraryFolders.flatMap { Self.downloads(for: stable, in: $0) }
                let existing = Set(downloads.map(\.metadata.enclosure))
                let window = limit.map {
                    Self.downloadWindow(episodes: subscription.automaticDownloads == false ? [] : ordered, existing: downloads, limit: $0)
                }
                let wanted = ordered.filter { window?.contains($0.enclosure.absoluteString) ?? !subscription.seen.contains($0.id) }
                var completed = true
                for episode in wanted where subscription.automaticDownloads != false && !existing.contains(episode.enclosure.absoluteString) {
                    guard !Task.isCancelled, library.downloadFolder == root, !DeviceManager.shared.busy,
                          shows.contains(where: { $0.id == subscription.id }) else { completed = false; break }
                    do {
                        let exists = FileManager.default.fileExists(atPath: stable.destination(for: episode, in: root).path)
                        try await stable.download(episode, into: root)
                        processed = true
                        if !exists { downloaded += 1 }
                        if library.downloadFolder == root { markSeen(episode, in: stable) }
                    } catch { failures += 1; completed = false }
                }
                if let window, completed, library.downloadFolder == root, !Task.isCancelled,
                   !DeviceManager.shared.busy, shows.contains(where: { $0.id == subscription.id }) {
                    var remaining = window
                    let sorted = downloads.sorted { $0.url.path < $1.url.path }
                    let expired = Set(sorted.filter { remaining.remove($0.metadata.enclosure) == nil }.compactMap {
                        library.mediaID(for: $0.url)
                    })
                    if !expired.isEmpty {
                        if expired.contains(where: { library.track($0) == nil }) && !library.isScanning { library.scan() }
                        while library.isScanning && library.downloadFolder == root && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        guard library.downloadFolder == root, !Task.isCancelled, !DeviceManager.shared.busy,
                              shows.contains(where: { $0.id == subscription.id }) else { continue }
                        let result = library.trashPodcastEpisodes(expired)
                        trimmed += result.removed.count
                        failures += result.failures.count
                        if let current = PlayerEngine.shared.current, result.removed.contains(current.id) { PlayerEngine.shared.stop() }
                    }
                }
            } catch { failures += 1 }
        }
        if processed, library.downloadFolder == root {
            while (library.isScanning || DeviceManager.shared.busy) && library.downloadFolder == root && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if library.downloadFolder == root && !Task.isCancelled {
                ArtworkLoader.shared.podcastArtworkChanged()
                library.scan()
            }
        }
        status = shows.isEmpty ? "" : [
            downloaded > 0 ? "\(downloaded) new episodes downloaded" : nil,
            trimmed > 0 ? "\(trimmed) older episodes moved to Trash" : nil,
            failures > 0 ? "\(failures) podcast operations failed" : nil
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shows) {
            UserDefaults.standard.set(data, forKey: "podcastSubscriptions")
        }
    }
}
