import SwiftUI

@MainActor
final class LyricsPresentation: ObservableObject {
    static let shared = LyricsPresentation()

    @Published private(set) var isVisible = false

    func toggle() {
        isVisible.toggle()
        MiniPlayerController.shared.resizeForLyrics()
    }
}

@MainActor
struct LyricsPane: View {
    @ObservedObject var player: PlayerEngine
    @State private var lyrics: Lyrics?
    @State private var plain = false
    @State private var follow = true

    @State private var onlineLyrics: Lyrics?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchStatus: String?
    @State private var readyTrack: Track.ID?

    private var displayed: Lyrics? {
        guard let lyrics else { return onlineLyrics }
        guard let onlineLyrics, lyrics.timed.isEmpty else { return lyrics }
        return Lyrics(plain: lyrics.plain.isEmpty ? onlineLyrics.plain : lyrics.plain, timed: onlineLyrics.timed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if onlineLyrics != nil {
                Divider()
                Link("Lyrics from LRCLIB", destination: URL(string: "https://lrclib.net")!)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.hex(0xF7F8FA))
        .task(id: player.current?.id) {
            cancelSearch()
            readyTrack = nil
            lyrics = nil
            onlineLyrics = nil
            searchStatus = nil
            plain = false
            follow = true
            guard let track = player.current else { return }
            let url = LibraryStore.shared.url(for: track)
            let local = await Task.detached(priority: .userInitiated) {
                url.map(Lyrics.load) ?? Lyrics(plain: "", timed: [])
            }.value
            let cached = local.timed.isEmpty ? await LyricsLookup.shared.cached(.init(track)) : nil
            guard !Task.isCancelled, player.current?.id == track.id else { return }
            lyrics = local
            onlineLyrics = cached
            readyTrack = track.id
        }
        .onDisappear { cancelSearch() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading) {
                    Text(player.current?.title ?? "Lyrics").font(Theme.listBoldFont(12)).lineLimit(1)
                    if let artist = player.current?.artist {
                        Text(artist).font(Theme.listFont(11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let displayed, !displayed.timed.isEmpty {
                    Picker("Lyrics view", selection: $plain) {
                        Text("Synced").tag(false)
                        Text("Text").tag(true)
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                } else if let track = player.current, readyTrack == track.id, LyricsLookup.Query(track).canSearch {
                    Button("Find Lyrics") { findLyrics(for: track) }
                        .buttonStyle(ChromeButtonStyle())
                        .disabled(searchTask != nil)
                }
            }
            if let searchStatus {
                Text(searchStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(12)
        .background(Theme.glossyHeader)
    }

    @ViewBuilder
    private var content: some View {
        if searchTask != nil, displayed?.plain.isEmpty != false {
            ProgressView()
        } else if let displayed, !displayed.timed.isEmpty, !plain {
            timedLyrics(displayed.timed)
        } else if let displayed, !displayed.plain.isEmpty {
            ScrollView {
                Text(displayed.plain).font(Theme.listFont(15)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } else if player.current == nil {
            ContentUnavailableView("Play a Track", systemImage: "music.note")
        } else if lyrics == nil {
            ProgressView()
        } else {
            VStack(spacing: 7) {
                Image(systemName: "quote.bubble").font(.system(size: 25))
                Text("No Lyrics Found").font(.headline)
                Text("Search online or add a matching .lrc or .txt file beside the track.")
                    .font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(18)
        }
    }

    private func findLyrics(for track: Track) {
        guard searchTask == nil else { return }
        searchStatus = "Searching LRCLIB…"
        searchTask = Task {
            do {
                let result = try await LyricsLookup.shared.find(.init(track))
                guard !Task.isCancelled, player.current?.id == track.id else { return }
                onlineLyrics = result
                if result?.timed.isEmpty == false { plain = false }
                searchStatus = result == nil ? "No matching lyrics found online." : nil
            } catch {
                guard !Task.isCancelled, player.current?.id == track.id else { return }
                searchStatus = (error as? LyricsLookup.Failure)?.errorDescription
                    ?? LyricsLookup.Failure.unavailable.errorDescription
            }
            searchTask = nil
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func timedLyrics(_ lines: [Lyrics.Line]) -> some View {
        let active = lines.lastIndex { $0.time <= player.position + 0.05 }
        return VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(lines.indices, id: \.self) { index in
                            Button {
                                player.seek(to: lines[index].time)
                            } label: {
                                Text(lines[index].text.isEmpty ? " " : lines[index].text)
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(active == index ? Color.primary : .secondary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).id(index)
                        }
                    }.padding(16)
                }
                .onChange(of: active, initial: true) {
                    if follow, let active { withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo(active, anchor: .center) } }
                }
                .onChange(of: follow) {
                    if follow, let active { scroll.scrollTo(active, anchor: .center) }
                }
            }
            Divider()
            Toggle("Follow Playback", isOn: $follow).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
        }
    }
}
