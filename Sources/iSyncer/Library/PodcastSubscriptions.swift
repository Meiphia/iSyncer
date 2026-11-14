import Foundation
import ClassicSync

@MainActor
final class PodcastSubscriptions: ObservableObject {
    static let shared = PodcastSubscriptions()

    struct Subscription: Codable, Identifiable {
        let id: URL
        let title: String
        var seen: Set<URL>

        var show: String { PathRules.sanitize(title) }
    }

    @Published private(set) var shows: [Subscription] = {
        guard let data = UserDefaults.standard.data(forKey: "podcastSubscriptions") else { return [] }
        return (try? JSONDecoder().decode([Subscription].self, from: data)) ?? []
    }()

    @Published private(set) var checking = false
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
        let ordered = feed.episodes.enumerated().sorted {
            let first = $0.element.publishedAt ?? .distantPast
            let second = $1.element.publishedAt ?? .distantPast
            return first == second ? $0.offset < $1.offset : first > second
        }.map(\.element)
        shows.append(.init(id: feed.url, title: feed.title, seen: Set(ordered.dropFirst().map(\.id))))
        save()
        Task { await refresh(library, feed: feed) }
    }

    func unfollow(_ url: URL) {
        shows.removeAll { $0.id == url }
        if shows.isEmpty { status = "" }
        save()
    }

    func refresh(_ library: LibraryStore, feed: PodcastFeed? = nil) async {
        if checking {
            if let feed { queuedFeeds.append(feed) }
            return
        }
        guard !DeviceManager.shared.busy, !shows.isEmpty, let root = library.libraryRoot,
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
        for subscription in shows where feed == nil || feed?.url == subscription.id {
            do {
                let current: PodcastFeed
                if let feed { current = feed }
                else { current = try await PodcastFeed.load(subscription.id.absoluteString) }
                // Keep the library's show folder stable if the publisher renames the feed.
                let stable = PodcastFeed(title: subscription.title, episodes: current.episodes, url: current.url,
                                         image: current.image, author: current.author)
                for episode in current.episodes where !subscription.seen.contains(episode.id) {
                    guard !Task.isCancelled, library.libraryRoot == root, !DeviceManager.shared.busy,
                          shows.contains(where: { $0.id == subscription.id }) else { break }
                    do {
                        let exists = FileManager.default.fileExists(atPath: stable.destination(for: episode, in: root).path)
                        try await stable.download(episode, into: root)
                        processed = true
                        if !exists { downloaded += 1 }
                        if library.libraryRoot == root, let index = shows.firstIndex(where: { $0.id == subscription.id }) {
                            shows[index].seen.insert(episode.id)
                            save()
                        }
                    } catch { failures += 1 }
                }
            } catch { failures += 1 }
        }
        if processed, library.libraryRoot == root {
            while (library.isScanning || DeviceManager.shared.busy) && library.libraryRoot == root && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if library.libraryRoot == root && !Task.isCancelled {
                ArtworkLoader.shared.podcastArtworkChanged()
                library.scan()
            }
        }
        status = shows.isEmpty ? "" : failures > 0 ? "\(downloaded) downloaded · \(failures) could not be checked or downloaded"
            : downloaded > 0 ? "\(downloaded) new episodes downloaded" : ""
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shows) {
            UserDefaults.standard.set(data, forKey: "podcastSubscriptions")
        }
    }
}
