import SwiftUI
import AppKit

// MARK: - Album artwork (column browser)

/// One album in the column browser's artwork view.
struct AlbumSummary: Identifiable {
    let name: String
    let year: Int
    let count: Int
    let first: Track
    var id: String { name }
}

/// The column browser's Album pane as a grid of covers (Show Album Artwork).
@MainActor
struct AlbumArtworkPane: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var browser: BrowserModel
    var onPlay: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10, alignment: .top)]

    var body: some View {
        let isPodcasts = browser.source == .podcasts
        let title = isPodcasts ? "Shows" : "Album"
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(browser.albumSel.isEmpty ? title : "\(title) — show all").font(textSize.font(11))
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.albumSel = [] }
            .overlay(alignment: .trailing) {
                if !isPodcasts {
                    Button { browser.showAlbumArtwork = false } label: {
                        Image(systemName: "list.bullet").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("Show albums as a list")
                }
            }
            .foregroundStyle(Theme.hex(0x222222))
            .frame(height: 17 + textSize.extra)
            .background(Theme.glossyHeader)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hex(0x8E8E8E)).frame(height: 1) }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(browser.albumSummaries) { a in
                        AlbumTile(album: a, highlighted: browser.albumSel.contains(a.name),
                                  item: isPodcasts ? "episode" : "song")
                            .onTapGesture {
                                browser.album = browser.album == a.name && NSApp.currentEvent?.clickCount == 1 ? nil : a.name
                                if NSApp.currentEvent?.clickCount == 2 {
                                    browser.album = a.name
                                    onPlay()
                                }
                            }
                            .help("\(a.name) — double-click to play")
                    }
                }
                .padding(10)
            }
            .background(Color.white)
            .contentShape(Rectangle())
        }
    }
}

@MainActor
struct AlbumTile: View {
    @Environment(\.interfaceTextSize) private var textSize
    let album: AlbumSummary
    var highlighted = false
    var item = "song"
    @ObservedObject private var artworkLoader = ArtworkLoader.shared
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                Rectangle().fill(Theme.hex(0xEEEEEE))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 22, weight: .ultraLight)).foregroundStyle(Theme.hex(0xAAAAAA))
                }
            }
            .frame(width: 76, height: 76)
            .clipped()
            .overlay(Rectangle().strokeBorder(highlighted ? Color(nsColor: ITStyle.selectionActive) : Theme.hex(0xBBBBBB),
                                              lineWidth: highlighted ? 2 : 1))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            Text(album.name.isEmpty ? "Unknown Album" : album.name)
                .font(textSize.bold(10)).lineLimit(1)
            Text([album.year > 0 ? String(album.year) : nil,
                  "\(album.count) \(item)\(album.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · "))
                .font(textSize.font(9)).foregroundStyle(Theme.hex(0x777777)).lineLimit(1)
        }
        .frame(width: 76)
        .foregroundStyle(Theme.hex(0x222222))
        .contentShape(Rectangle())
        .task(id: [album.first.id, album.first.podcastShow == nil ? "" : String(artworkLoader.podcastRevision)]) { image = await ArtworkLoader.shared.image(for: album.first) }
    }
}

// MARK: - Party Shuffle bar

@MainActor
struct PartyShuffleBar: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var party: PartyShuffle

    var body: some View {
        HStack(spacing: 10) {
            Text("Source: Library").font(textSize.font(10))
            Spacer()
            Text("Display").font(textSize.font(10))
            Text("\(party.recentCount) recently played").font(textSize.font(10)).foregroundStyle(Theme.hex(0x666666))
            Picker("", selection: $party.upcomingCount) {
                ForEach([5, 10, 15, 25, 50, 100], id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 60)
            Text("upcoming songs").font(textSize.font(10))
            Button("Refresh") { party.refresh() }
                .controlSize(.mini)
        }
        .foregroundStyle(Theme.hex(0x222222))
        .padding(.horizontal, 10)
        .frame(height: 24 + textSize.extra)
        .background(Theme.glossyHeader)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hex(0xA0A0A0)).frame(height: 1) }
    }
}

// MARK: - Visualizer

/// An original visualizer driven by the live spectrum: mirrored glowing bars over a slowly
/// turning ring of light, with the song name fading in at the bottom.
@MainActor
struct VisualizerView: View {
    @ObservedObject var player: PlayerEngine
    @ObservedObject private var spectrum = SpectrumModel.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let levels = spectrum.levels
                Canvas { g, size in
                    Self.draw(in: &g, size: size, time: t, levels: levels)
                }
            }
            if let c = player.current {
                VStack(spacing: 2) {
                    Text(c.title).font(.system(size: 15, weight: .semibold))
                    Text([c.artist, c.album].filter { !$0.isEmpty }.joined(separator: " — ")).font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { SpectrumModel.shared.attach() }
        .onDisappear { SpectrumModel.shared.detach() }
    }

    nonisolated private static func draw(in g: inout GraphicsContext, size: CGSize, time t: Double, levels: [Float]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let energy = CGFloat(levels.prefix(6).reduce(0, +) / 6)
        let hueBase = (t * 0.03).truncatingRemainder(dividingBy: 1)

        // Ring of light.
        let radius = min(size.width, size.height) * (0.22 + 0.10 * energy)
        let ringCount = 64
        for i in 0..<ringCount {
            let a = Double(i) / Double(ringCount) * 2 * .pi + t * 0.25
            let band = levels.isEmpty ? 0 : CGFloat(levels[i % levels.count])
            let r = radius + band * radius * 0.9
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            let d = 3 + band * 9
            let hue = (hueBase + Double(i) / Double(ringCount) * 0.35).truncatingRemainder(dividingBy: 1)
            g.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                   with: .color(Color(hue: hue, saturation: 0.7, brightness: 1, opacity: 0.55)))
        }

        // Mirrored bars across the middle.
        let n = max(levels.count, 1)
        let barW = size.width / CGFloat(n * 2 + 2)
        var glow = g
        glow.addFilter(.blur(radius: 6))
        for (i, level) in levels.enumerated() {
            let h = CGFloat(level) * size.height * 0.42
            let hue = (hueBase + Double(i) / Double(n) * 0.5).truncatingRemainder(dividingBy: 1)
            let color = Color(hue: hue, saturation: 0.8, brightness: 1)
            for side in [-1.0, 1.0] {
                let x = center.x + CGFloat(side) * (CGFloat(i) + 0.5) * barW * 1.0 - barW * 0.35
                let rect = CGRect(x: x, y: center.y - h, width: barW * 0.7, height: h * 2)
                glow.fill(Path(roundedRect: rect, cornerRadius: barW * 0.3), with: .color(color.opacity(0.5)))
                g.fill(Path(roundedRect: rect, cornerRadius: barW * 0.3), with: .color(color.opacity(0.85)))
            }
        }
    }
}

// MARK: - Equalizer window

@MainActor
final class EqualizerWindowController: NSObject, NSWindowDelegate {
    static let shared = EqualizerWindowController()
    private var window: NSWindow?

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); return }
        show()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 230),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Equalizer"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .aqua)
            w.contentView = NSHostingView(rootView: EqualizerView(eq: .shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
struct EqualizerView: View {
    @ObservedObject var eq: EqualizerModel
    private let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Toggle("On", isOn: $eq.enabled)
                Spacer()
                Picker("", selection: Binding(
                    get: { eq.presetName },
                    set: { name in if let p = EQPreset.all.first(where: { $0.name == name }) { eq.choose(p) } }
                )) {
                    if !EQPreset.all.contains(where: { $0.name == eq.presetName }) {
                        Text(eq.presetName).tag(eq.presetName)
                    }
                    ForEach(EQPreset.all) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 0) {
                    Text("+12 dB").frame(height: 14)
                    Spacer()
                    Text("0 dB")
                    Spacer()
                    Text("-12 dB").frame(height: 14)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 130)
                band("Preamp", value: Binding(get: { eq.preamp }, set: { eq.preamp = $0 }))
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 140)
                ForEach(0..<10, id: \.self) { i in
                    band(labels[i], value: Binding(get: { eq.gains.indices.contains(i) ? eq.gains[i] : 0 },
                                                   set: { eq.setGain($0, band: i) }))
                }
            }
            .disabled(!eq.enabled)
            .opacity(eq.enabled ? 1 : 0.55)
        }
        .padding(14)
        .frame(width: 470)
    }

    private func band(_ label: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }),
                   in: -12...12)
                .controlSize(.small)
                .frame(width: 130)
                .rotationEffect(.degrees(-90))
                .frame(width: 26, height: 130)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
        }
    }
}

// MARK: - Mini player

/// AppKit's title bar can add space to a short window when it is shown.
final class MiniPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MiniPlayerContentView: NSView {
    static let trafficLightsWidth: CGFloat = 68

    init(hosting: NSView) {
        super.init(frame: .zero)
        let dragArea = WindowDragArea.DragView()
        dragArea.acceptsInactiveDrag = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        // Keep the drag area above the SwiftUI host so AppKit delivers the mouse event to it.
        addSubview(dragArea)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            dragArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trafficLightsWidth),
            dragArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: MiniPlayerController.trafficLightInset)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private struct MiniWindowButtons: NSViewRepresentable {
    @MainActor final class Actions: NSObject {
        @objc func close() { MiniPlayerController.shared.showMain() }
        @objc func minimize(_ sender: NSButton) { sender.window?.miniaturize(nil) }
        @objc func expand() { MiniPlayerController.shared.showMain() }
    }

    func makeCoordinator() -> Actions { Actions() }

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let controls: [(NSWindow.ButtonType, Selector, String)] = [
            (.closeButton, #selector(Actions.close), "Close Mini Player"),
            (.miniaturizeButton, #selector(Actions.minimize(_:)), "Minimize"),
            (.zoomButton, #selector(Actions.expand), "Back to the full window")
        ]
        for (type, action, label) in controls {
            guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.isEnabled = true
            button.target = context.coordinator
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            stack.addArrangedSubview(button)
        }
        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {}
}

/// The green window button switches to a small always-on-top player, like iTunes did.
/// Option-click zooms normally.
@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate {
    static let shared = MiniPlayerController()
    weak var mainWindow: NSWindow?
    var revealAlbum: ((Track) -> Void)?
    private var mini: NSWindow?
    static let width: CGFloat = 520
    static let trafficLightInset: CGFloat = 29
    static func controlsHeight(_ size: InterfaceTextSize) -> CGFloat { 108 + 2 * size.extra }
    static let lyricsHeight: CGFloat = 290

    @objc func toggleFromZoomButton(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.option) {
            ((sender as? NSView)?.window ?? mainWindow)?.zoom(nil)
            return
        }
        if let w = (sender as? NSView)?.window, w !== mini { mainWindow = w }
        toggle()
    }

    var isShowing: Bool { mini?.isVisible ?? false }

    func toggle() {
        if isShowing { showMain() } else { showMini() }
    }

    func showMini() {
        if mini == nil {
            let w = MiniPlayerWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.controlsHeight(.saved)),
                             styleMask: [.borderless, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "iSyncer Mini Player"
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.appearance = NSAppearance(named: .aqua)
            w.delegate = self
            let hosting = NSHostingView(rootView: MiniPlayerView(player: .shared, library: .shared, devices: .shared).interfaceTypography())
            hosting.sizingOptions = []
            w.contentView = MiniPlayerContentView(hosting: hosting)
            w.setFrameAutosaveName("iSyncer.MiniPlayer")
            if !w.setFrameUsingName("iSyncer.MiniPlayer") { w.center() }
            mini = w
        }
        mainWindow?.orderOut(nil)
        if mini?.isMiniaturized == true { mini?.deminiaturize(nil) }
        mini?.makeKeyAndOrderFront(nil)
        resizeForLyrics()
    }

    func resizeForLyrics() {
        guard let w = mini else { return }
        let frame = w.frame
        let height = Self.controlsHeight(.saved) + (LyricsPresentation.shared.isVisible ? Self.lyricsHeight + 1 : 0)
        var target = NSRect(x: frame.minX, y: frame.maxY - height, width: Self.width, height: height)
        if let visible = (w.screen ?? NSScreen.main)?.visibleFrame {
            target.origin.y = max(visible.minY, min(target.minY, visible.maxY - target.height))
        }
        w.setFrame(target, display: true)
    }

    @objc private func miniZoom(_ sender: Any?) { showMain() }

    func showMain() {
        mini?.orderOut(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mini { mainWindow?.makeKeyAndOrderFront(nil) }
    }
}

@MainActor
struct MiniPlayerView: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore
    @ObservedObject var devices: DeviceManager
    @ObservedObject private var lyrics = LyricsPresentation.shared
    @State private var cover: NSImage?
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            if lyrics.isVisible {
                Rectangle().fill(Theme.chromeLine).frame(height: 1)
                    .accessibilityHidden(true)
                LyricsPane(player: player)
                    .frame(height: MiniPlayerController.lyricsHeight)
            }
        }
        .frame(width: MiniPlayerController.width)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: textSize) { MiniPlayerController.shared.resizeForLyrics() }
        .preferredColorScheme(.light)
    }

    private var titleStrip: some View {
        HStack(spacing: 0) {
            MiniWindowButtons()
                .frame(width: MiniPlayerContentView.trafficLightsWidth - 8, height: 18)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .frame(height: MiniPlayerController.trafficLightInset)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            titleStrip
            playbackControls
                .padding(.bottom, 3)
                .padding(.horizontal, 12)
        }
        .frame(width: MiniPlayerController.width, height: MiniPlayerController.controlsHeight(textSize), alignment: .top)
        .background(Theme.chrome)
    }

    private var playbackControls: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    guard let track = player.current else { return }
                    MiniPlayerController.shared.showMain()
                    MiniPlayerController.shared.revealAlbum?(track)
                } label: {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.6))
                        if let cover { Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit) }
                        else { Image(systemName: "music.note").foregroundStyle(.secondary) }
                    }
                    .frame(width: 46, height: 46)
                    .border(Theme.chromeLine)
                }
                .buttonStyle(.plain)
                .help("Show album in Library")
                LCDDisplay(player: player, library: library, devices: devices, compact: true)
                Button { lyrics.toggle() } label: { Image(systemName: "quote.bubble") }
                    .buttonStyle(ChromeButtonStyle(active: lyrics.isVisible))
                    .help(lyrics.isVisible ? "Hide lyrics" : "Show lyrics")
                    .accessibilityLabel(lyrics.isVisible ? "Hide lyrics" : "Show lyrics")
                Button { showQueue.toggle() } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Up Next")
                    .popover(isPresented: $showQueue) { upNext }
            }
            HStack(spacing: 8) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(RoundButtonStyle(diameter: 20))
                Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(RoundButtonStyle(diameter: 24))
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(RoundButtonStyle(diameter: 20))
                Spacer()
                if let track = player.current {
                    let rating = library.track(track.id)?.rating ?? track.rating
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { stars in
                            Button { library.setRating([track.id], rating == stars ? 0 : stars) } label: {
                                Image(systemName: stars <= rating ? "star.fill" : "star")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Rate \(stars) stars")
                        }
                    }
                }
                Spacer()
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 65)
                    .accessibilityLabel("Volume")
            }
        }
        .task(id: player.current?.id) {
            cover = nil
            guard let track = player.current else { return }
            let image = await ArtworkLoader.shared.image(for: track)
            if !Task.isCancelled { cover = image }
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next").font(.headline)
            let queued = player.upcoming
            if queued.isEmpty {
                Text("The queue is empty.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(queued, id: \.offset) { item in
                            if let track = library.track(item.id) {
                                Button {
                                    player.playUpcoming(at: item.offset, id: item.id)
                                    showQueue = false
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(track.title).lineLimit(1)
                                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 275, height: queuedHeight)
    }

    private var queuedHeight: CGFloat { player.upcoming.isEmpty ? 74 : 260 }
}

// MARK: - Library Health bar

@MainActor
struct HealthBar: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var browser: BrowserModel
    @ObservedObject var health: LibraryHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(HealthCheck.allCases) { c in
                    Button {
                        browser.healthCheck = c
                        if c == .noArtwork, !health.artworkChecked, health.artworkProgress == nil { health.checkArtwork() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(c.label)
                            Text(health.count(c).map { $0.formatted() } ?? "–")
                                .font(textSize.font(10))
                                .padding(.horizontal, 5)
                                .background(Capsule().fill((health.count(c) ?? 0) > 0 ? Color.orange.opacity(0.25) : Color.green.opacity(0.2)))
                        }
                        .font(textSize.font(11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(browser.healthCheck == c ? Color(nsColor: ITStyle.selectionActive) : Color.white.opacity(0.6)))
                        .foregroundStyle(browser.healthCheck == c ? Color.white : Theme.hex(0x222222))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if health.analyzing { ProgressView().controlSize(.small) }
                Button("Check Again") {
                    health.analyze()
                    if browser.healthCheck == .noArtwork { health.checkArtwork() }
                }
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(browser.healthCheck.explanation)
                    .font(textSize.font(10))
                    .foregroundStyle(Theme.hex(0x555555))
                    .lineLimit(2)
                if browser.healthCheck == .noArtwork, let p = health.artworkProgress {
                    ProgressView(value: p).frame(width: 120)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.glossyHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hex(0xA0A0A0)).frame(height: 1) }
    }
}
