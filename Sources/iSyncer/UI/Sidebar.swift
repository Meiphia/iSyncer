import SwiftUI
import AppKit

/// The iTunes 6 "Source" list: one flat list (Library, Videos, Party Shuffle, devices,
/// smart playlists, playlists) under a glossy header, with the artwork pane at the bottom.
@MainActor
struct Sidebar: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var browser: BrowserModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var devices: DeviceManager
    @ObservedObject var player: PlayerEngine
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @ObservedObject private var artworkLoader = ArtworkLoader.shared
    @State private var artwork: NSImage?
    @AppStorage("artworkShowsSelection") private var artworkShowsSelection = false

    var body: some View {
        VStack(spacing: 0) {
            GlossyHeader(title: "Source")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(.library, icon: SourceIcon(symbol: "music.note", color: Theme.hex(0x2F6BC9)),
                        title: "Library", onDoubleClick: playLibrary)
                    row(.videos, icon: SourceIcon(symbol: "film", color: Theme.hex(0x4A4A4A)), title: "Videos")
                    row(.podcasts, icon: SourceIcon(symbol: "mic", color: Theme.hex(0x7554A3)), title: "Podcasts")
                    row(.audiobooks, icon: SourceIcon(symbol: "book", color: Theme.hex(0xA26D3E)), title: "Audiobooks")
                    row(.partyShuffle, icon: SourceIcon(symbol: "shuffle", color: Theme.hex(0x8A4FC7)),
                        title: "Party Shuffle", onDoubleClick: { PartyShuffle.shared.play(at: 0) })
                    row(.health, icon: SourceIcon(symbol: "stethoscope", color: Theme.hex(0x3C8E4A)), title: "Library Health")

                    ForEach(devices.connected) { device in
                        deviceRow(device)
                    }

                    Rectangle().fill(Theme.hex(0xB7C1CF)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)

                    ForEach(LibraryStore.smartPlaylistNames, id: \.self) { name in
                        if let list = library.builtInSmartList(named: name) {
                            row(.smart(name), icon: SourceIcon(symbol: "gearshape.fill", color: Theme.hex(0x7E5BC2)),
                                title: list.name, onDoubleClick: { playSmart(name) })
                            .contextMenu {
                                Button("Edit Smart Playlist…") { SmartPlaylistEditor.shared.open(list) }
                                Button("Play") { playSmart(name) }
                                if library.smartList(list.id) != nil {
                                    Button("Reset to Default") { library.deleteSmartList(list.id) }
                                }
                            }
                        }
                    }
                    ForEach(library.customSmartLists) { sl in
                        row(.smartList(sl.id), icon: SourceIcon(symbol: "gearshape.fill", color: Theme.hex(0x7E5BC2)),
                            title: sl.name, onDoubleClick: { playSmartList(sl.id) })
                        .contextMenu {
                            Button("Edit Smart Playlist…") { SmartPlaylistEditor.shared.open(sl) }
                            Button("Play") { playSmartList(sl.id) }
                            Divider()
                            Button("Delete Playlist", role: .destructive) {
                                if browser.source == .smartList(sl.id) { browser.source = .library }
                                library.deleteSmartList(sl.id)
                            }
                        }
                    }
                    ForEach(library.playlists) { pl in
                        row(.playlist(pl.id),
                            icon: SourceIcon(symbol: pl.isImported ? "doc.text" : "music.note.list", color: Theme.hex(0x2F6BC9)),
                            title: pl.name,
                            onDoubleClick: { play(pl) })
                        .draggable(LibraryStore.playlistDragPrefix + pl.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, onto: pl)
                        }
                        .contextMenu {
                            Button("Rename…") { renameText = pl.name; renaming = pl }
                            Button("Play") { play(pl) }
                            Divider()
                            Button("Delete Playlist", role: .destructive) {
                                if browser.source == .playlist(pl.id) { browser.source = .library }
                                library.deletePlaylist(pl.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            if browser.showArtwork {
                artworkPane
                    .layoutPriority(1)
            }
        }
        .background(Theme.sourceBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hex(0x8E8E8E)).frame(width: 1)
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let pl = renaming { library.renamePlaylist(pl.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task(id: [artworkTrack?.id ?? "", artworkTrack?.podcastShow == nil ? "" : String(artworkLoader.podcastRevision)]) {
            if let t = artworkTrack { artwork = await ArtworkLoader.shared.image(for: t) } else { artwork = nil }
        }
    }

    // MARK: Rows

    private func row(_ sel: SourceSelection, icon: SourceIcon, title: String,
                     onDoubleClick: @escaping () -> Void = {}) -> some View {
        let selected = browser.source == sel
        return HStack(spacing: 5) {
            icon.frame(width: 16)
            Text(title)
                .font(selected ? textSize.bold(12) : textSize.font(12))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .foregroundStyle(selected ? Color.white : Theme.hex(0x111111))
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 19 + textSize.extra)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyView(Theme.selection) : AnyView(Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            // One gesture: AppKit's click count tells a double-click apart instantly.
            browser.source = sel
            if NSApp.currentEvent?.clickCount == 2 { onDoubleClick() }
        }
    }

    private func deviceRow(_ device: ClassicDevice) -> some View {
        row(.device(device.id), icon: SourceIcon(symbol: "ipod", color: Theme.hex(0x4A4A4A)),
            title: device.value.name)
            .contextMenu {
                Button("Eject") { devices.eject(device) }.disabled(devices.busy)
            }
    }

    // MARK: Artwork pane

    private var artworkTrack: Track? {
        if artworkShowsSelection, let id = browser.selection.first, let t = library.track(id) { return t }
        return player.current
    }

    private var artworkPane: some View {
        VStack(spacing: 0) {
            Button {
                artworkShowsSelection.toggle()
            } label: {
                GlossyHeader(title: artworkShowsSelection ? "Selected Song" : (player.current == nil ? "Nothing Playing" : "Now Playing"))
            }
            .buttonStyle(.plain)
            .help("Click to switch between the playing song and the selected song")
            Color.white
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "music.note")
                                .font(.system(size: 34, weight: .ultraLight))
                            Text(artworkTrack == nil ? "" : "No Artwork").font(textSize.font(10))
                        }
                        .foregroundStyle(Theme.hex(0xB0B0B0))
                    }
                }
                .clipped()
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.hex(0x8E8E8E)).frame(height: 1) }
    }

    // MARK: Actions

    /// Songs dropped on a playlist are added; a playlist dropped on another moves before it.
    private func drop(_ items: [String], onto pl: Playlist) -> Bool {
        if let first = items.first, first.hasPrefix(LibraryStore.playlistDragPrefix) {
            guard let id = UUID(uuidString: String(first.dropFirst(LibraryStore.playlistDragPrefix.count))) else { return false }
            library.movePlaylist(id, before: pl.id)
            return true
        }
        let ids = items.filter { library.track($0) != nil }
        guard !ids.isEmpty else { return false }
        library.add(ids, to: pl.id)
        return true
    }

    private func playLibrary() {
        let ids = library.tracks.filter(\.isMusic).map(\.id)
        guard !ids.isEmpty else { return }
        player.play(queue: ids, startAt: 0)
    }

    private func play(_ pl: Playlist) {
        let ids = library.tracks(in: pl).map(\.id)
        guard !ids.isEmpty else { return }
        player.play(queue: ids, startAt: 0)
    }

    private func playSmartList(_ id: UUID) {
        let ids = library.tracks(inSmart: id).map(\.id)
        guard !ids.isEmpty else { return }
        player.play(queue: ids, startAt: 0)
    }

    private func playSmart(_ name: String) {
        guard let pl = library.smartPlaylist(named: name) else { return }
        play(pl)
    }
}

struct SourceIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
    }
}

/// Glossy grey bar used for "Source", "Now Playing" and similar pane titles.
struct GlossyHeader: View {
    @Environment(\.interfaceTextSize) private var textSize
    let title: String

    var body: some View {
        Text(title)
            .font(textSize.font(12))
            .foregroundStyle(Theme.hex(0x222222))
            .frame(maxWidth: .infinity)
            .frame(height: 18 + textSize.extra)
            .background(Theme.glossyHeader)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hex(0x8E8E8E)).frame(height: 1) }
    }
}
