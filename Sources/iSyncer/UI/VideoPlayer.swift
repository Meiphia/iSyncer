import AppKit
import AVKit
import SwiftUI

@MainActor
struct LibraryVideoPlayer: View {
    let video: VideoItem
    let url: URL
    let next: VideoItem?
    let playNext: (VideoItem) -> Void
    @State private var player = AVPlayer()
    @State private var ended = false
    @State private var failed = false
    @State private var started = false
    @State private var checkpoint: Double = 0
    @State private var observer: Any?
    @State private var itemStatus: NSKeyValueObservation?
    @State private var audio: AVMediaSelectionGroup?
    @State private var subtitles: AVMediaSelectionGroup?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(video.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                if let audio, audio.options.count > 1 { trackMenu("Audio", group: audio) }
                if let subtitles, !subtitles.options.isEmpty { trackMenu("Subtitles", group: subtitles) }
                Button("Open in Default Player") {
                    player.pause()
                    NSWorkspace.shared.open(url)
                }
            }.padding(12).background(Theme.chrome)
            if failed {
                ContentUnavailableView("Can’t Play This Video", systemImage: "film",
                    description: Text("Try opening the original file in your default player."))
            } else {
                NativeVideoSurface(player: player)
            }
            if ended, let next {
                HStack {
                    Text("Up Next: \(next.displayTitle)").lineLimit(1)
                    Spacer()
                    Button("Play Next Episode") { playNext(next) }
                }.padding(12).background(Theme.chrome)
            }
        }
        .frame(minWidth: 680, minHeight: 430)
        .task {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            itemStatus = item.observe(\.status, options: [.new]) { item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    if player.currentItem === item { failed = true }
                }
            }
            let resume = VideoWatchHistory.shared.state(at: url)
            checkpoint = resume.watched ? 0 : resume.seconds
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in
                    guard !ended, player.currentItem === item else { return }
                    if item.status == .failed { failed = true }
                    guard started, time.seconds.isFinite, abs(time.seconds - checkpoint) >= 5 else { return }
                    checkpoint = time.seconds
                    save()
                }
            }
            let playable = (try? await item.asset.load(.isPlayable)) == true
            guard !Task.isCancelled else { return }
            guard playable, item.status != .failed else { failed = true; return }
            if checkpoint > 0 {
                let duration = (try? await item.asset.load(.duration))?.seconds ?? 0
                if !duration.isFinite || duration <= 0 || checkpoint < duration - 1 {
                    await player.seek(to: CMTime(seconds: checkpoint, preferredTimescale: 600))
                }
            }
            guard !Task.isCancelled else { return }
            if PlayerEngine.shared.isPlaying { PlayerEngine.shared.togglePlayPause() }
            started = true
            player.play()
            let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled else { return }
            self.audio = audio
            self.subtitles = subtitles
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            ended = true
            VideoWatchHistory.shared.update(url, seconds: 0, duration: item.duration.seconds, watched: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            if let item = note.object as? AVPlayerItem, item === player.currentItem { failed = true }
        }
        .onDisappear {
            player.pause()
            if started && !ended { save() }
            if let observer { player.removeTimeObserver(observer); self.observer = nil }
            itemStatus = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    private func trackMenu(_ title: String, group: AVMediaSelectionGroup) -> some View {
        Menu(title) {
            if group.allowsEmptySelection {
                Button("Off") { player.currentItem?.select(nil, in: group) }
            }
            ForEach(Array(group.options.enumerated()), id: \.offset) { _, option in
                Button(option.displayName) { player.currentItem?.select(option, in: group) }
            }
        }.fixedSize()
    }

    private func save() {
        VideoWatchHistory.shared.update(url, seconds: player.currentTime().seconds,
                                        duration: player.currentItem?.duration.seconds ?? 0)
    }
}

private struct NativeVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
