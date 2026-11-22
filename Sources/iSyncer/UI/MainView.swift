import SwiftUI
import AppKit

@MainActor
struct MainView: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerEngine
    @ObservedObject var devices: DeviceManager
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var podcasts = PodcastSubscriptions.shared
    @ObservedObject private var lyrics = LyricsPresentation.shared
    @State private var showPodcastDiscovery = false
    @State private var podcastFeedToBrowse: URL?
    @AppStorage("columnBrowserHeight") private var browserHeight: Double = 310

    var body: some View {
        VStack(spacing: 0) {
            TopBar(player: player, browser: browser, library: library, devices: devices)
            HStack(spacing: 0) {
                PersistentSplit(autosaveName: "iSyncer.Main", panes: [
                    .init(view: AnyView(Sidebar(browser: browser, library: library, devices: devices, player: player)),
                          minWidth: 150, maxWidth: 360, initialWidth: 210, holding: 260),
                    .init(view: AnyView(detail.frame(maxWidth: .infinity, maxHeight: .infinity)),
                          minWidth: 520, holding: 240)
                ])
                if lyrics.isVisible {
                    Rectangle().fill(Theme.chromeLine).frame(width: 1)
                        .accessibilityHidden(true)
                    LyricsPane(player: player)
                        .frame(width: 270)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Lyrics")
                }
            }
            StatusBar(browser: browser, library: library, player: player, devices: devices)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .onAppear { [weak browser = browser] in
            MiniPlayerController.shared.revealAlbum = { [weak browser] track in
                browser?.showCoverFlow = false
                browser?.showVisualizer = false
                browser?.showAlbum(of: track)
            }
        }
        .frame(minWidth: lyrics.isVisible ? 1002 : 900, minHeight: 520)
        .preferredColorScheme(.light)
        .onChange(of: browser.source) { _, _ in browser.showExpandedPlayer = false }
        .onReceive(devices.didConnect) { id in
            browser.showCoverFlow = false
            browser.showVisualizer = false
            browser.source = .device(id)
            let windows = MiniPlayerController.shared
            windows.mainWindow?.deminiaturize(nil)
            NSApp.activate()
            windows.showMain()
        }
        .sheet(isPresented: $showPodcastDiscovery) { PodcastDownloadSheet(library: library, initialFeed: podcastFeedToBrowse) }
        .alert("iSyncer", isPresented: Binding(get: { devices.message != nil }, set: { if !$0 { devices.message = nil } })) {
            Button("OK") { devices.message = nil }
        } message: {
            Text(devices.message ?? "")
        }
    }

    @State private var showVideoHealth = false

    @ViewBuilder
    private var detail: some View {
        if library.libraryRoot == nil {
            WelcomeView(library: library)
        } else if browser.showExpandedPlayer {
            ExpandedNowPlaying(player: player, library: library, visible: $browser.showExpandedPlayer)
        } else if browser.showCoverFlow {
            CoverFlowView(library: library, player: player, visible: $browser.showCoverFlow)
        } else {
            switch browser.source {
            case .videos:
                VideoPage(library: library, search: browser.search)
            case .artists:
                ArtistPages(library: library, player: player, browser: browser)
            case .device(let id):
                ClassicDevicePage(id: id, devices: devices, library: library)
            case .library, .podcasts, .audiobooks, .playlist, .smart, .partyShuffle, .health, .smartList:
                if browser.source == .health && showVideoHealth {
                    VStack(spacing: 0) {
                        healthTabs
                        VideoHealthView(library: library, search: browser.search)
                    }
                } else if browser.showVisualizer && browser.source != .health {
                    VisualizerView(player: player)
                } else {
                    // Plain VStack + custom handles instead of VSplitView: NSSplitView-backed views can
                    // spin in layout when a pane appears/disappears (e.g. switching to a playlist).
                    VStack(spacing: 0) {
                        if browser.showColumnBrowser && !browser.isListSource {
                            Group {
                                if browser.source == .podcasts {
                                    AlbumArtworkPane(browser: browser, onPlay: playVisible, controls: AnyView(podcastControls))
                                } else {
                                    ColumnBrowser(browser: browser, onPlay: playVisible)
                                }
                            }
                            .frame(height: browserHeight)
                            SplitHandle(value: $browserHeight, range: 80...600)
                        } else if browser.source == .podcasts {
                            podcastControls
                        }
                        if browser.source == .health {
                            healthTabs
                            HealthBar(browser: browser, health: LibraryHealth.shared)
                        }
                        songList
                        if browser.source == .partyShuffle {
                            PartyShuffleBar(party: PartyShuffle.shared)
                        }
                    }
                }
            }
        }
    }

    private var podcastControls: some View {
        HStack(spacing: 8) {
            Spacer()
            Toggle("Unplayed", isOn: $browser.showUnplayedPodcasts)
            if let feed = selectedPodcastFeed {
                Button("Browse Feed…") { browsePodcast(feed) }
            }
            if !podcasts.shows.isEmpty {
                Menu("Followed Shows") {
                    Button("Check for New Episodes") { Task { await podcasts.refresh(library) } }
                        .disabled(podcasts.checking || devices.busy)
                    ForEach(podcasts.shows) { show in
                        Menu(show.title) {
                            Button("Show Episodes") {
                                browser.albumSel = []
                                browser.search = show.show
                            }
                            Button("Browse Feed…") { browsePodcast(show.id) }
                            Button("Unfollow") { podcasts.unfollow(show.id) }
                        }
                    }
                }
                .fixedSize()
            }
            Button("Find & Download Podcasts…") { browsePodcast(nil) }
                .fixedSize()
        }
        .font(textSize.font(11))
        .controlSize(.mini)
        .padding(.horizontal, 9)
        .frame(height: Theme.paneHeaderHeight + textSize.extra)
        .background(Theme.chrome)
    }

    private func browsePodcast(_ feed: URL?) {
        podcastFeedToBrowse = feed
        showPodcastDiscovery = true
    }

    private var selectedPodcastFeed: URL? {
        guard let show = browser.album else { return nil }
        if let followed = podcasts.shows.first(where: { $0.show == show }) { return followed.id }
        guard let episode = browser.albumSummaries.first(where: { $0.name == show })?.first,
              let url = library.url(for: episode),
              let address = try? String(contentsOf: url.deletingLastPathComponent().appending(path: ".feed-url"), encoding: .utf8),
              let feed = URL(string: address), PodcastFeed.isWebURL(feed) else { return nil }
        return feed
    }

    private var healthTabs: some View {
        HStack {
            Picker("Library Health", selection: $showVideoHealth) {
                Text("Music").tag(false)
                Text("TV & Movies").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
        .padding(8)
        .background(Theme.statusBar)
    }

    private func playVisible() {
        let ids = browser.visibleIDs
        if !ids.isEmpty { player.play(queue: ids, startAt: 0) }
    }

    @ViewBuilder
    private var songList: some View {
        if browser.isPlaylist && browser.visible.isEmpty && browser.search.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list").font(.system(size: 40, weight: .ultraLight))
                Text("This playlist is empty.")
                Text("Drag songs here, or right-click songs → Add to Playlist.").font(.system(size: 11 + textSize.extra))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        } else {
            SongTable(browser: browser, library: library, isPodcasts: browser.source == .podcasts)
                .id(browser.source == .podcasts)
        }
    }
}

/// Hides the title bar (the chrome draws it), keeps the traffic lights, and sends the green
/// zoom button to the mini player like iTunes did.
struct WindowConfigurator: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = false
            MiniPlayerController.shared.mainWindow = w
            if let zoom = w.standardWindowButton(.zoomButton) {
                zoom.target = MiniPlayerController.shared
                zoom.action = #selector(MiniPlayerController.toggleFromZoomButton(_:))
                zoom.toolTip = "Switch to the mini player (Option-click to zoom)"
            }
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
struct WelcomeView: View {
    @ObservedObject var library: LibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(Theme.hex(0x5A6B85))
            Text("Welcome to iSyncer").font(.system(size: 20, weight: .semibold))
            Text("Pick your media library: the folder holding your music and videos (for example one with Music, TV and Movies inside). iSyncer reads it, plays it, and syncs music to your iPod Classic.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Choose Media Library…") { chooseLibraryFolder(library) }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}

@MainActor
func chooseLibraryFolder(_ library: LibraryStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add Folders"
    panel.message = "Add media folders to your library. Manage or remove them in Settings → Library."
    if panel.runModal() == .OK {
        do { try library.addFolders(panel.urls) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Add Library Folders"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

@MainActor
struct StatusBar: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var browser: BrowserModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerEngine
    @ObservedObject var devices: DeviceManager
    @ObservedObject private var loudness = LoudnessAnalyzer.shared
    @ObservedObject private var podcasts = PodcastSubscriptions.shared

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Playlist") {
                    let id = library.createPlaylist(name: "untitled playlist")
                    browser.source = .playlist(id)
                }
                Button("Smart Playlist") {
                    SmartPlaylistEditor.shared.open { [weak browser] id in browser?.source = .smartList(id) }
                }
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Add Playlist")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a playlist or smart playlist")
            Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle") }
                .buttonStyle(ChromeButtonStyle(active: player.shuffle, compact: true))
                .help("Shuffle")
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
            }
            .buttonStyle(ChromeButtonStyle(active: player.repeatMode != .off, compact: true))
            .help("Repeat")
            Button { browser.showArtwork.toggle() } label: { Image(systemName: "photo") }
                .buttonStyle(ChromeButtonStyle(active: browser.showArtwork, compact: true))
                .help("Show or hide song artwork")

            if browser.source == .podcasts || browser.source == .audiobooks {
                let inProgress = browser.visible.filter { ($0.resumePosition ?? 0) > 0 && $0.finishedListening != true }
                if !inProgress.isEmpty {
                    Menu("Continue Listening") {
                        ForEach(inProgress) { track in
                            Button("\(track.title) · \(Format.duration(track.resumePosition ?? 0))") {
                                player.play(queue: [track.id], startAt: 0)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Spacer()
            Text(centerText)
                .font(textSize.font(11))
                .foregroundStyle(Theme.hex(0x333333))
                .lineLimit(1)
            Spacer()

            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(ChromeButtonStyle(compact: true))
                .help("Settings")
                .accessibilityLabel("Settings")
            Button { EqualizerWindowController.shared.toggle() } label: { Image(systemName: "slider.vertical.3") }
                .buttonStyle(ChromeButtonStyle(compact: true))
                .help("Equalizer")
            Button { browser.showVisualizer.toggle() } label: { Image(systemName: "sparkles") }
                .buttonStyle(ChromeButtonStyle(active: browser.showVisualizer, compact: true))
                .help("Visualizer")
            Button { browser.showAlbumArtwork.toggle() } label: { Image(systemName: "square.grid.2x2") }
                .buttonStyle(ChromeButtonStyle(active: browser.showAlbumArtwork, compact: true))
                .help("Show album artwork in the column browser")
            Button { ejectSelected() } label: { Image(systemName: "eject.fill") }
                .buttonStyle(ChromeButtonStyle(compact: true))
                .disabled(ejectable == nil || devices.busy)
                .help("Eject the selected device")
        }
        .padding(.horizontal, 8)
        .frame(height: 30 + textSize.extra)
        .background(Theme.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
    }

    private var ejectable: ClassicDevice? {
        if case .device(let id) = browser.source, let device = devices.device(id) { return device }
        return devices.connected.first
    }

    private func ejectSelected() {
        if let device = ejectable { devices.eject(device) }
    }

    private var centerText: String {
        if loudness.running {
            return "Measuring loudness: \(loudness.done.formatted()) of \(loudness.total.formatted()) songs"
        }
        if case .device(let id) = browser.source, let device = devices.device(id)?.value {
            return "\(device.trackCount.formatted()) items on device · \(Format.bytes(device.available)) free"
        }
        if browser.source == .podcasts && !podcasts.status.isEmpty { return podcasts.status }
        return browser.summary
    }
}

/// Horizontal drag handle between the column browser and the song list.
@MainActor
struct SplitHandle: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// For a pane below the handle: dragging up makes it taller.
    var inverted = false
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Theme.hex(0xE6E6E6), Theme.hex(0xC4C4C4)], startPoint: .top, endPoint: .bottom))
            .frame(height: 6)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hex(0x9A9A9A)).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hex(0x9A9A9A)).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let v = (dragStart ?? value) + (inverted ? -g.translation.height : g.translation.height)
                        value = min(max(v, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
