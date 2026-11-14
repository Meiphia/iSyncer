import SwiftUI
import AppKit

/// The full-height window top in the iTunes 6 style: window title on the chrome, transport and
/// volume on the left, the display in the middle, Search and Browse (with captions) on the right.
/// The traffic lights sit in the chrome's top-left corner; the empty chrome drags the window.
@MainActor
struct TopBar: View {
    @ObservedObject var player: PlayerEngine
    @ObservedObject var browser: BrowserModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var devices: DeviceManager
    @ObservedObject private var lyrics = LyricsPresentation.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("iSyncer")
                .font(Theme.listFont(12))
                .foregroundStyle(Theme.hex(0x2A2A2A))
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .allowsHitTesting(false)
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 5) {
                    transport
                    volume
                }
                .padding(.leading, 6)
                Spacer(minLength: 10)
                LCDDisplay(player: player, library: library, devices: devices)
                    .frame(minWidth: 340, idealWidth: 470, maxWidth: 540)
                Spacer(minLength: 10)
                captioned("Search") { searchField }
                captioned("Browse") {
                    Button { browser.showColumnBrowser.toggle() } label: { BrowseEye(open: browser.showColumnBrowser) }
                        .buttonStyle(RoundButtonStyle(diameter: 30))
                        .help("Show or hide the column browser")
                }
                captioned("Lyrics") {
                    Button { lyrics.toggle() } label: {
                        Image(systemName: lyrics.isVisible ? "quote.bubble.fill" : "quote.bubble")
                    }
                    .buttonStyle(RoundButtonStyle(diameter: 30))
                    .help(lyrics.isVisible ? "Hide lyrics" : "Show lyrics")
                    .accessibilityLabel(lyrics.isVisible ? "Hide lyrics" : "Show lyrics")
                }
                .padding(.trailing, 4)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .frame(height: 87)
        .background(WindowDragArea())
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
    }

    private func captioned<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 3) {
            content()
            Text(caption)
                .font(Theme.listFont(10))
                .foregroundStyle(Theme.hex(0x3A3A3A))
                .shadow(color: .white.opacity(0.6), radius: 0, y: 1)
        }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(RoundButtonStyle(diameter: 32))
                .help("Previous")
            Button {
                if player.current == nil { playSelectionOrFirst() } else { player.togglePlayPause() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(RoundButtonStyle(diameter: 40))
            .help("Play/Pause")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(RoundButtonStyle(diameter: 32))
                .help("Next")
        }
    }

    private var volume: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill").font(.system(size: 8)).foregroundStyle(Theme.hex(0x444444))
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 80)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 8)).foregroundStyle(Theme.hex(0x444444))
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.hex(0x777777))
            TextField("", text: $browser.search)
                .textFieldStyle(.plain)
                .font(Theme.listFont(11))
            if !browser.search.isEmpty {
                Button { browser.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.hex(0x9A9A9A))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(width: 170)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Theme.hex(0x6E6E6E), lineWidth: 1))
        .shadow(color: .white.opacity(0.6), radius: 0, y: 1)
    }

    private func playSelectionOrFirst() {
        if browser.source == .partyShuffle {
            PartyShuffle.shared.play(at: 0)
            return
        }
        let ids = browser.visibleIDs
        guard !ids.isEmpty else { return }
        let start = browser.selection.first.flatMap { sel in ids.firstIndex(of: sel) } ?? 0
        player.play(queue: ids, startAt: start)
    }
}

/// The eye on the Browse button (an original drawing): open when the browser is showing.
struct BrowseEye: View {
    let open: Bool

    var body: some View {
        ZStack {
            Ellipse()
                .stroke(Theme.hex(0x2A2A2A), lineWidth: 1.4)
                .frame(width: 16, height: open ? 9 : 2)
            if open {
                Circle().fill(Theme.hex(0x2A2A2A)).frame(width: 5, height: 5)
            }
        }
        .frame(width: 18, height: 12)
    }
}

/// Lets the empty chrome drag the window (the title bar is hidden).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performMiniaturize(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - The display

enum LCDMode: String {
    case info, spectrum
}

/// The pale display in the middle of the chrome: song info with a progress bar (second line
/// alternates artist and album), or a live spectrum; scan or sync progress when busy.
@MainActor
struct LCDDisplay: View {
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore
    @ObservedObject var devices: DeviceManager
    var compact = false
    @AppStorage("lcdMode") private var mode: LCDMode = .info
    @AppStorage("lcdShowRemaining") private var showRemaining = false
    @State private var scrubbing: Double?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.lcd)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.lcdStroke, lineWidth: 1))
                .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.black.opacity(0.18), lineWidth: 2)
                        .blur(radius: 1.5)
                        .offset(y: 1)
                        .mask(RoundedRectangle(cornerRadius: 7))
                )
            content
                .padding(.horizontal, compact ? 8 : 12)
                .padding(.vertical, 5)
        }
        .frame(height: compact ? 44 : 54)
    }

    @ViewBuilder
    private var content: some View {
        if devices.busy {
            VStack(spacing: 4) {
                Text(devices.status).font(Theme.listFont(11)).lineLimit(1)
                if let progress = devices.progress {
                    ScrubBar(fraction: progress, interactive: false).frame(height: 8)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: 260)
                }
            }
            .foregroundStyle(Theme.lcdText)
        } else if let t = player.current {
            HStack(spacing: 6) {
                Button {
                    mode = mode == .info ? .spectrum : .info
                } label: {
                    Image(systemName: mode == .info ? "waveform" : "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.lcdDim)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(mode == .info ? "Show the spectrum" : "Show song info")
                if mode == .spectrum {
                    LCDSpectrum()
                } else {
                    nowPlaying(t)
                }
            }
        } else if library.isScanning || !library.scanStatus.isEmpty {
            VStack(spacing: 4) {
                Text(library.scanStatus.isEmpty ? "Scanning…" : library.scanStatus)
                    .font(Theme.listFont(11))
                    .foregroundStyle(Theme.lcdText)
                if library.isScanning { ProgressView().controlSize(.small).progressViewStyle(.linear).frame(maxWidth: 260) }
            }
        } else {
            idle
        }
    }

    private var idle: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: compact ? 16 : 22, weight: .light))
            if !compact {
                Text("iSyncer")
                    .font(.system(size: 15, weight: .light, design: .rounded))
                    .tracking(1.5)
            }
        }
        .foregroundStyle(Theme.lcdDim)
    }

    private func nowPlaying(_ t: Track) -> some View {
        let duration = max(player.duration, 0.01)
        let pos = scrubbing ?? player.position
        let second = [t.artist, t.album].filter { !$0.isEmpty }
        return VStack(spacing: 1) {
            Text(t.title)
                .font(Theme.listFont(compact ? 10 : 11))
                .lineLimit(1)
            // Second line alternates between artist and album every few seconds.
            TimelineView(.periodic(from: .now, by: 3.5)) { ctx in
                let i = second.isEmpty ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / 3.5) % second.count
                Text(second.isEmpty ? " " : second[i])
                    .font(Theme.listFont(compact ? 10 : 11))
                    .foregroundStyle(Theme.lcdDim)
                    .lineLimit(1)
                    .id(i)
                    .transition(.opacity)
            }
            HStack(spacing: 5) {
                Text(Format.duration(pos))
                    .font(Theme.listFont(10).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                ScrubBar(fraction: pos / duration) { f in
                    scrubbing = f * duration
                } onEnd: { f in
                    player.seek(to: f * duration)
                    scrubbing = nil
                }
                .frame(height: 8)
                Text(showRemaining ? "-" + Format.duration(duration - pos) : Format.duration(duration))
                    .font(Theme.listFont(10).monospacedDigit())
                    .frame(width: 42, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showRemaining.toggle() }
            }
            if let msg = player.message, !compact {
                Text(msg).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
            }
        }
        .foregroundStyle(Theme.lcdText)
    }
}

/// Spectrum bars inside the display.
@MainActor
struct LCDSpectrum: View {
    @ObservedObject private var spectrum = SpectrumModel.shared

    var body: some View {
        GeometryReader { geo in
            let levels = spectrum.levels
            let n = max(levels.count, 1)
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<levels.count, id: \.self) { i in
                    Rectangle()
                        .fill(Theme.lcdText.opacity(0.75))
                        .frame(width: w, height: max(1, geo.size.height * CGFloat(levels[i])))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .padding(.vertical, 2)
        .onAppear { SpectrumModel.shared.attach() }
        .onDisappear { SpectrumModel.shared.detach() }
    }
}

/// iTunes-style progress: a thin outlined track, darkened up to the playhead, with a black
/// diamond knob. Draggable unless `interactive` is false.
struct ScrubBar: View {
    var fraction: Double
    var interactive = true
    var onScrub: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    init(fraction: Double, interactive: Bool = true,
         onScrub: ((Double) -> Void)? = nil, onEnd: ((Double) -> Void)? = nil) {
        self.fraction = fraction
        self.interactive = interactive
        self.onScrub = onScrub
        self.onEnd = onEnd
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .overlay(Rectangle().strokeBorder(Theme.lcdText.opacity(0.85), lineWidth: 1))
                    .frame(height: h * 0.75)
                Rectangle()
                    .fill(Theme.lcdText.opacity(0.55))
                    .frame(width: max(0, w * f), height: h * 0.75)
                if interactive {
                    Rectangle()
                        .fill(Theme.lcdText)
                        .frame(width: h * 0.85, height: h * 0.85)
                        .rotationEffect(.degrees(45))
                        .offset(x: w * f - h * 0.425)
                }
            }
            .frame(height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onScrub?(min(max(v.location.x / w, 0), 1)) }
                    .onEnded { v in onEnd?(min(max(v.location.x / w, 0), 1)) }
            )
            .allowsHitTesting(interactive)
        }
    }
}
