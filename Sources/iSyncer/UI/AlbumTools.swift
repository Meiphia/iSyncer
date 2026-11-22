import AppKit
import SwiftUI

struct LibraryEdition: Identifiable {
    let id: String
    let tracks: [Track]

    var first: Track { tracks[0] }
    var label: String {
        let name = first.classicEditionLabel
        return name.isEmpty ? first.album : name
    }

    static func editions(in tracks: [Track]) -> [LibraryEdition] {
        Dictionary(grouping: tracks.filter { $0.isMusic && !$0.album.isEmpty }, by: \.classicEditionKey)
            .map { LibraryEdition(id: $0.key, tracks: Scanner.sortCanonical($0.value)) }
            .sorted { first, second in
                let order = first.first.album.localizedStandardCompare(second.first.album)
                return order == .orderedSame ? first.id < second.id : order == .orderedAscending
            }
    }
}

extension Track {
    var classicEditionKey: String {
        var parent = (id as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent.range(of: #"^(cd|disc|disk)\s*[-_ ]?\d+$"#,
                                                        options: [.regularExpression, .caseInsensitive]) != nil {
            parent = (parent as NSString).deletingLastPathComponent
        }
        return classicAlbumKey + "\u{1f}" + parent
    }

    var classicEditionLabel: String {
        let parent = classicEditionKey.components(separatedBy: "\u{1f}").last ?? ""
        return (parent as NSString).lastPathComponent
    }

    fileprivate var albumFamily: String {
        let stem = album.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(deluxe|remaster|anniversary|expanded|edition|box set)[^\)\]]*[\)\]]\s*|\s+[-–—]\s+.*(deluxe|remaster|anniversary|expanded|edition|box set).*"#,
                                              with: "", options: [.regularExpression, .caseInsensitive])
        return "\(displayAlbumArtist)\u{1f}\(stem.trimmingCharacters(in: .whitespacesAndNewlines))".lowercased()
    }
}

@MainActor
struct CoverFlowView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerEngine
    @Binding var visible: Bool
    @State private var index = 0
    @State private var grouped = false
    @State private var editions: [LibraryEdition] = []
    @FocusState private var focused: Bool

    var body: some View {
        let groups = grouped ? Dictionary(grouping: editions, by: { $0.first.albumFamily }).values
            .compactMap(\.first).sorted { $0.first.album.localizedStandardCompare($1.first.album) == .orderedAscending } : editions
        let cursor = groups.indices.contains(index) ? index : 0
        VStack(spacing: 20) {
            HStack {
                Text("Cover Flow").font(.headline)
                Spacer()
                Toggle("Group editions", isOn: $grouped)
                Button("Close Cover Flow") { visible = false }
            }
            if let edition = groups.indices.contains(cursor) ? groups[cursor] : nil {
                GeometryReader { bounds in
                    let side = min(280, max(100, bounds.size.width / 2.5), max(100, bounds.size.height - 16))
                    HStack(spacing: 12) {
                        ForEach(Array(max(0, cursor - 2)..<min(groups.count, cursor + 3)), id: \.self) { position in
                            Button {
                                if position == cursor { player.play(queue: edition.tracks.map(\.id), startAt: 0) }
                                else { index = position }
                            } label: {
                                FlowCover(track: groups[position].first)
                                    .frame(width: position == cursor ? side : side * 0.44, height: position == cursor ? side : side * 0.44)
                                    .rotation3DEffect(.degrees(position == cursor ? 0 : position < cursor ? 33 : -33), axis: (0, 1, 0))
                                    .opacity(position == cursor ? 1 : 0.67)
                            }
                            .buttonStyle(.plain)
                            .help(groups[position].first.album)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(spacing: 6) {
                    Text(edition.first.album).font(.title2.bold())
                    Text(edition.first.displayAlbumArtist).foregroundStyle(.secondary)
                    let variants = editions.filter { $0.first.albumFamily == edition.first.albumFamily }
                    if variants.count > 1 {
                        Menu("Editions · \(variants.count)") {
                            ForEach(variants) { variant in
                                Button("\(variant.first.album) · \(variant.label)") {
                                    grouped = false
                                    index = editions.firstIndex { $0.id == variant.id } ?? 0
                                }
                            }
                        }.fixedSize()
                    }
                    HStack {
                        Button { index = max(0, cursor - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(cursor == 0).accessibilityLabel("Previous album")
                        Button("Play Album") { player.play(queue: edition.tracks.map(\.id), startAt: 0) }
                        Button("Add to Queue") { player.enqueue(edition.tracks.map(\.id)) }
                        Button { index = min(groups.count - 1, cursor + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(cursor + 1 == groups.count).accessibilityLabel("Next album")
                    }
                    Slider(value: Binding(get: { Double(cursor) }, set: { index = Int($0) }),
                           in: 0...Double(max(1, groups.count - 1)), step: 1)
                        .labelsHidden().disabled(groups.count < 2).frame(maxWidth: 420)
                        .accessibilityLabel("Album position")
                }
            } else {
                ContentUnavailableView("No albums", systemImage: "square.stack")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($focused)
        .onAppear { editions = LibraryEdition.editions(in: library.tracks); focused = true }
        .onChange(of: library.tracks) { editions = LibraryEdition.editions(in: library.tracks) }
        .onChange(of: grouped) { if !groups.indices.contains(index) { index = 0 } }
        .onKeyPress(.leftArrow) { index = max(0, cursor - 1); return .handled }
        .onKeyPress(.rightArrow) { index = max(0, min(groups.count - 1, cursor + 1)); return .handled }
        .onKeyPress(.return) {
            if groups.indices.contains(cursor) { player.play(queue: groups[cursor].tracks.map(\.id), startAt: 0) }
            return .handled
        }
        .onExitCommand { visible = false }
    }
}

private struct FlowCover: View {
    let track: Track
    @ObservedObject private var loader = ArtworkLoader.shared
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: [track.id, String(loader.podcastRevision)]) { image = await loader.image(for: track) }
    }
}

enum RediscoverMode: String, CaseIterable {
    case oldAlbums = "Albums I Haven’t Played in a Year"
    case favorites = "Old Favorites"
    case unplayed = "Never Played"

    @MainActor
    func run(library: LibraryStore, save: Bool) {
        let music = library.tracks.filter { $0.isMusic && library.isChecked($0.id) }
        let yearAgo = (Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()).timeIntervalSince1970
        let picks: [Track]
        switch self {
        case .oldAlbums:
            let editions = LibraryEdition.editions(in: music).filter {
                $0.tracks.contains { $0.lastPlayed > 0 } && $0.tracks.allSatisfy { $0.lastPlayed < yearAgo }
            }
            picks = editions.shuffled().prefix(4).flatMap(\.tracks)
        case .favorites:
            picks = Array(music.filter { $0.rating >= 4 && $0.lastPlayed < yearAgo }.shuffled().prefix(25))
        case .unplayed:
            picks = Array(music.filter { $0.playCount == 0 }.shuffled().prefix(25))
        }
        guard !picks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No matching tracks"
            alert.informativeText = rawValue
            alert.runModal()
            return
        }
        let ids = picks.map(\.id)
        if save {
            let id = library.createPlaylist(name: rawValue, trackIDs: ids)
            BrowserModelLink.browser?.source = .playlist(id)
        } else {
            PlayerEngine.shared.play(queue: ids, startAt: 0, partyShuffle: true)
        }
    }
}
