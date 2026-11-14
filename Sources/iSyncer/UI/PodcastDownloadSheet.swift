import SwiftUI

struct PodcastDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptions = PodcastSubscriptions.shared
    @State private var query = ""
    @State private var results: [PodcastShow]?
    @State private var manualRSS = false
    @State private var feedURL = ""
    @ObservedObject var library: LibraryStore
    @State private var feed: PodcastFeed?
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
                List(activeFeed.episodes, selection: $selection) { episode in
                    Text(episode.title).lineLimit(2).tag(episode.id)
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
                        .disabled(work != nil || selection == nil || library.isScanning || library.libraryRoot == nil)
                }
            }
            if library.libraryRoot == nil {
                Button("Choose Media Library…") { chooseLibraryFolder(library) }
                    .disabled(work != nil)
            }
        }
        .padding(18)
        .frame(width: 610, height: 400)
        .interactiveDismissDisabled(work != nil)
        .onDisappear { work?.cancel() }
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

    private func loadFeed(_ address: String) {
        guard work == nil else { return }
        feed = nil
        selection = nil
        start("Loading feed…") {
            feed = try await PodcastFeed.load(address)
            selection = feed?.episodes.first?.id
            status = ""
        }
    }

    private func download() {
        guard work == nil, let feed, let episode = feed.episodes.first(where: { $0.id == selection }),
              let root = library.libraryRoot else { return }
        start("Downloading episode…") {
            try await feed.download(episode, into: root)
            if library.libraryRoot == root {
                ArtworkLoader.shared.podcastArtworkChanged()
                library.scan()
            }
            status = "Episode saved to the library."
        }
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
