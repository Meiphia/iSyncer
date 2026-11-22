import SwiftUI

struct PodcastDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptions = PodcastSubscriptions.shared
    @State private var query = ""
    @State private var results: [PodcastShow]?
    @State private var manualRSS = false
    @State private var feedURL = ""
    @ObservedObject var library: LibraryStore
    var initialFeed: URL? = nil
    @State private var feed: PodcastFeed?
    @State private var downloaded = Set<URL>()
    @State private var downloadedOnly = false
    @State private var selection: URL?
    @State private var work: Task<Void, Never>?
    @State private var status = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download Podcast Episodes").font(.headline)
            HStack {
                TextField("Search for a podcast", text: $query).onSubmit(search)
                Button("Search", action: search).disabled(work != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(manualRSS ? "Hide RSS" : "Enter RSS…") { manualRSS.toggle() }
            }
            .disabled(work != nil)
            if manualRSS {
                HStack {
                    TextField("Podcast RSS feed URL", text: $feedURL).onSubmit { loadFeed(feedURL) }
                    Button("Load Feed") { loadFeed(feedURL) }
                        .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(work != nil)
            }
            if let activeFeed = feed {
                HStack {
                    if results != nil {
                        Button("Back to Results") { feed = nil; selection = nil; status = "" }
                            .disabled(work != nil)
                    }
                    Text(activeFeed.title).font(.subheadline.bold())
                    Spacer()
                    if subscriptions.shows.contains(where: { $0.id == activeFeed.url }) {
                        Button("Unfollow") { subscriptions.unfollow(activeFeed.url) }
                    } else {
                        Button("Follow") { subscriptions.follow(activeFeed, library: library) }
                    }
                }
                if let subscription = subscriptions.shows.first(where: { $0.id == activeFeed.url }) {
                    downloadOptions(subscription)
                }
                Toggle("Downloaded", isOn: $downloadedOnly)
                    .onChange(of: downloadedOnly) { _, enabled in
                        if enabled, let selection, !downloaded.contains(selection) { self.selection = nil }
                    }
                let episodes = activeFeed.newestFirst.filter { !downloadedOnly || downloaded.contains($0.id) }
                List(episodes, selection: $selection) { episode in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(episode.title).lineLimit(2)
                            if let date = episode.publishedAt {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if downloaded.contains(episode.id) {
                            Label("Downloaded", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(episode.id)
                }
                .overlay {
                    if episodes.isEmpty { Text("No downloaded episodes in this feed").foregroundStyle(.secondary) }
                }
                .border(Theme.hex(0xB8B8B8))
            } else if let matches = results, !matches.isEmpty {
                List(matches) { show in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(show.collectionName).bold()
                            if let artist = show.artistName { Text(artist).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("View Episodes") { loadFeed(show.feedUrl.absoluteString) }
                            .disabled(work != nil)
                    }
                }
                .border(Theme.hex(0xB8B8B8))
            } else {
                Text(results == nil ? "Search by show name or publisher." : "No podcasts with a public RSS feed found.")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            HStack {
                if work != nil { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(failed ? .red : .secondary)
                Spacer()
                Button(work == nil ? "Done" : "Cancel") {
                    if let work { work.cancel() }
                    else { dismiss() }
                }
                if feed != nil {
                    Button("Download Episode", action: download)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(work != nil || subscriptions.checking || subscriptions.downloading || DeviceManager.shared.busy ||
                                  selection == nil || selection.map(downloaded.contains) == true || library.isScanning || library.downloadFolder == nil)
                }
            }
            if library.downloadFolder == nil {
                Button("Choose Media Library…") { chooseLibraryFolder(library) }
                    .disabled(work != nil)
            }
        }
        .padding(18)
        .frame(width: 610, height: 500)
        .interactiveDismissDisabled(work != nil)
        .onDisappear { work?.cancel() }
        .onChange(of: subscriptions.checking) { _, checking in if !checking { updateDownloaded() } }
        .onChange(of: library.libraryFolders) { _, _ in updateDownloaded() }
        .task { if let initialFeed { loadFeed(initialFeed.absoluteString, subscriptionID: initialFeed) } }
    }

    private func downloadOptions(_ subscription: PodcastSubscriptions.Subscription) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Automatically download episodes", isOn: Binding(
                get: { subscription.automaticDownloads != false },
                set: { value in var updated = subscription; updated.automaticDownloads = value; subscriptions.update(updated) }
            ))
            Toggle("Limit downloads on this Mac", isOn: Binding(
                get: { subscription.downloadLimit != nil },
                set: { value in var updated = subscription; updated.downloadLimit = value ? 20 : nil; subscriptions.update(updated) }
            ))
            if let limit = subscription.downloadLimit {
                Stepper("Keep only the newest \(limit) downloads", value: Binding(
                    get: { limit },
                    set: { value in var updated = subscription; updated.downloadLimit = value; subscriptions.update(updated) }
                ), in: 1...max(100, limit))
                Text("Older downloads go to the Trash on the next successful check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(subscriptions.checking || subscriptions.downloading || work != nil)
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard work == nil, !term.isEmpty else { return }
        feed = nil
        selection = nil
        results = nil
        start("Searching podcasts…") {
            results = try await PodcastDirectory.search(term)
            status = ""
        }
    }

    private func loadFeed(_ address: String, subscriptionID: URL? = nil) {
        guard work == nil else { return }
        feed = nil
        selection = nil
        start("Loading feed…") {
            let loaded = try await PodcastFeed.load(address)
            feed = subscriptions.stableFeed(loaded, subscriptionID: subscriptionID)
            downloadedOnly = false
            updateDownloaded()
            selection = feed?.newestFirst.first?.id
            status = ""
        }
    }

    private func download() {
        guard work == nil, let feed, let episode = feed.newestFirst.first(where: { $0.id == selection }) else { return }
        start("Downloading episode…") {
            try await subscriptions.download(episode, in: feed, library: library)
            updateDownloaded()
            status = "Episode saved to the library."
        }
    }

    private func updateDownloaded() {
        guard let feed, !library.libraryFolders.isEmpty else { downloaded = []; return }
        downloaded = Set(library.libraryFolders.flatMap { PodcastSubscriptions.downloads(for: feed, in: $0) }.compactMap { URL(string: $0.metadata.enclosure) })
    }

    private func start(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        status = message
        failed = false
        work = Task {
            defer { work = nil }
            do {
                try await action()
            } catch {
                if Task.isCancelled {
                    status = "Cancelled"
                } else {
                    status = error.localizedDescription
                    failed = true
                }
            }
        }
    }
}
