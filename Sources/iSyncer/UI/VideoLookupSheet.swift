import ClassicSync
import AppKit
import SwiftUI

@MainActor
struct VideoLookupSheet: View {
    let video: VideoItem
    var batch: TVMetadataBatch?
    var rememberedMatch: VideoDirectory.Match?
    var onRemember: ((VideoDirectory.Match) -> Void)?
    var onUse: ((VideoMetadataEdit, Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var season = 1
    @State private var episode = 1
    @State private var results: [VideoDirectory.Match] = []
    @State private var selectedID: Int?
    @State private var token = ""
    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var work: Task<Void, Never>?
    @State private var status = ""
    @State private var error: String?
    @State private var updates: [VideoDirectory.EpisodeUpdate]?
    @State private var included = Set<VideoItem.ID>()
    @State private var applied = Set<VideoItem.ID>()
    @State private var comparisons: [VideoItem.ID: [SyncMetadataChange]] = [:]

    private var isTV: Bool { video.kind == .tv }
    private var selected: VideoDirectory.Match? { results.first { $0.id == selectedID } }
    private var busy: Bool { work != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Video Metadata").font(.headline)
            if showToken {
                SecureField("TMDB API Read Access Token", text: $tokenInput)
                HStack {
                    Link("Get a TMDB token", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    Spacer()
                    Button("Save Token") {
                        let value = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        CredentialStore.write(VideoDirectory.tokenAccount, value)
                        token = value
                        tokenInput = ""
                        showToken = false
                        search()
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if let updates, let batch {
                Text(batch.label).fontWeight(.medium)
                let matched = updates.filter { $0.metadata != nil }.count
                Text("\(matched) matched · \(updates.count - matched) unmatched").foregroundStyle(.secondary)
                List(updates) { update in
                    VStack(alignment: .leading, spacing: 3) {
                        if let metadata = update.metadata {
                            Toggle("S\(update.video.season) E\(update.video.episode) · \(update.video.title) → \(metadata.title ?? update.video.title)", isOn: Binding(
                                get: { included.contains(update.id) },
                                set: { enabled in
                                    if enabled { included.insert(update.id) } else { included.remove(update.id) }
                                }))
                                .disabled(applied.contains(update.id))
                            if let date = metadata.releaseDate {
                                Text(date, format: .iso8601.year().month().day()).font(.caption).foregroundStyle(.secondary)
                            }
                            if let overview = metadata.overview {
                                Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if let changes = comparisons[update.id], !changes.isEmpty {
                                DisclosureGroup("Compare Metadata") { MetadataComparison(changes: changes) }
                            }
                        } else {
                            Text("\(update.video.displayTitle) · \(update.video.episode <= 0 ? "Missing episode number" : "No match")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 255)
                HStack {
                    Button("Back") {
                        self.updates = nil
                        error = nil
                        applied = []
                    }
                    Spacer()
                    Button("Save \(included.subtracting(applied).count) Episodes") { save(updates, batch: batch) }
                        .disabled(included.subtracting(applied).isEmpty)
                }
            } else {
                if let batch { Text(batch.label).foregroundStyle(.secondary) }
                if let rememberedMatch, selectedID == rememberedMatch.id {
                    Text("Saved TMDB match: \(rememberedMatch.displayTitle)").foregroundStyle(.secondary)
                }
                HStack {
                    TextField(isTV ? "Show title" : "Movie title", text: $query).onSubmit(search)
                    Button("Search", action: search)
                        .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if isTV && batch == nil {
                    HStack {
                        Text("Season")
                        TextField("Season", value: $season, format: .number.grouping(.never)).labelsHidden().frame(width: 52)
                        Text("Episode")
                        TextField("Episode", value: $episode, format: .number.grouping(.never)).labelsHidden().frame(width: 52)
                    }
                }
                List(results, selection: $selectedID) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.year.isEmpty ? item.displayTitle : "\(item.displayTitle) (\(item.year))").fontWeight(.medium)
                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .tag(item.id)
                }
                .frame(height: 215)
                .disabled(busy)
                HStack {
                    Button("Change TMDB Token…") { showToken = true }
                        .disabled(busy)
                    Spacer()
                    Button(batch == nil ? "Use Match" : "Review Episodes") { useMatch() }
                        .disabled(busy || selected == nil || (batch == nil && isTV && (season < 0 || episode < 1)))
                }
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                TMDBCredits()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            query = isTV ? video.show : video.title
            season = video.season
            episode = video.episode
            token = CredentialStore.read(VideoDirectory.tokenAccount) ?? ""
            showToken = token.isEmpty
            if let rememberedMatch, isTV {
                results = [rememberedMatch]
                selectedID = rememberedMatch.id
            } else if !showToken {
                search()
            }
        }
        .onDisappear { work?.cancel() }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !busy, !token.isEmpty else { return }
        results = []
        selectedID = nil
        run("Searching TMDB…") {
            let matches = try await VideoDirectory.search(term, tv: isTV, token: token)
            try Task.checkCancellation()
            results = matches
            selectedID = matches.first { $0.year == String(video.year) }?.id ?? matches.first?.id
            if matches.isEmpty { error = "No matches. Try a different title." }
        }
    }

    private func useMatch() {
        guard let selected, !busy else { return }
        if let batch {
            run("Matching episodes…") {
                let result = try await VideoDirectory.episodeUpdates(for: selected, videos: batch.videos, token: token)
                var comparisons: [VideoItem.ID: [SyncMetadataChange]] = [:]
                for update in result {
                    try Task.checkCancellation()
                    if let metadata = update.metadata, let current = await batch.current(update.video) {
                        comparisons[update.id] = current.changes(to: metadata)
                    }
                }
                try Task.checkCancellation()
                self.comparisons = comparisons
                included = Set(result.filter { $0.metadata != nil }.map(\.id))
                updates = result
            }
            return
        }
        let episodeNumber = isTV ? (season, episode) : nil
        run("Fetching metadata…") {
            let (metadata, missingArtwork) = try await VideoDirectory.metadata(for: selected, episode: episodeNumber, token: token)
            try Task.checkCancellation()
            if isTV { onRemember?(selected) }
            onUse?(metadata, missingArtwork)
            dismiss()
        }
    }

    private func save(_ updates: [VideoDirectory.EpisodeUpdate], batch: TVMetadataBatch) {
        let pending = included.subtracting(applied)
        let result = batch.save(updates.filter { pending.contains($0.id) })
        applied.formUnion(result.saved)
        if !result.saved.isEmpty, let selected { onRemember?(selected) }
        if let error = result.error {
            self.error = "\(applied.count) saved. \(error)"
        } else {
            dismiss()
        }
    }

    private func run(_ message: String, operation: @escaping @MainActor () async throws -> Void) {
        error = nil
        status = message
        work = Task {
            defer { work = nil }
            do { try await operation() }
            catch is CancellationError {}
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct TVMetadataBatch: Identifiable {
    let videos: [VideoItem]
    let label: String
    let current: @MainActor (VideoItem) async -> VideoMetadataEdit?
    let save: @MainActor ([VideoDirectory.EpisodeUpdate]) -> (saved: Set<VideoItem.ID>, error: String?)
    var id: String { label }
}

struct TMDBCredits: View {
    var body: some View {
        HStack(spacing: 8) {
            if let url = Bundle.main.url(forResource: "TMDB", withExtension: "svg"), let logo = NSImage(contentsOf: url) {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 32, height: 26)
                        .accessibilityLabel("The Movie Database")
                }
            }
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
