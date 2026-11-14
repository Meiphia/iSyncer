import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            LastFMSettings(lastfm: .shared)
                .tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
            DiscordSettings().tabItem { Label("Discord", systemImage: "bubble.left.and.bubble.right") }
            PlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            TMDBCredits()
                .padding()
                .tabItem { Label("Credits", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 560)
        .preferredColorScheme(.light)
    }
}

@MainActor
private struct LastFMSettings: View {
    @ObservedObject var lastfm: LastFM
    @State private var working = false

    var body: some View {
        Form {
            Section {
                if lastfm.isConnected {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Connected as \(lastfm.username ?? "?")")
                        Spacer()
                        Button("Disconnect") { lastfm.disconnect() }
                    }
                } else {
                    TextField("API key", text: $lastfm.apiKey)
                    SecureField("Shared secret", text: $lastfm.apiSecret)
                    Text("Create a free API account at last.fm/api/account/create (any name and description; leave the callback URL empty) and paste its API key and shared secret here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Last.fm API page") {
                            NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/account/create")!)
                        }
                        Spacer()
                        if lastfm.pendingToken == nil {
                            Button("Connect…") { run { await lastfm.beginConnect() } }
                                .disabled(!lastfm.hasCredentials || working)
                        } else {
                            Button("Finish Connecting") { run { await lastfm.finishConnect() } }
                                .keyboardShortcut(.defaultAction)
                                .disabled(working)
                        }
                    }
                }
            }
            Section("Scrobble") {
                Toggle("Songs played in iSyncer (shown live as “Scrobbling now”)", isOn: $lastfm.scrobbleApp)
                Toggle("Plays imported from iPod", isOn: $lastfm.scrobbleDevice)
                ThresholdRow()
                if lastfm.isConnected, let np = lastfm.nowPlayingTitle {
                    Text("Now playing on your profile: \(np)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Queue") {
                HStack {
                    Text("\(lastfm.queue.count) waiting to be sent")
                    Spacer()
                    Button("Send Now") { run { await lastfm.flush() } }
                        .disabled(!lastfm.isConnected || lastfm.queue.isEmpty || working)
                    Button("Clear") { lastfm.clearQueue() }
                        .disabled(lastfm.queue.isEmpty)
                }
                if !lastfm.status.isEmpty {
                    Text(lastfm.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        working = true
        Task { await work(); working = false }
    }
}

@MainActor
private struct PlaybackSettings: View {
    @State private var cacheSize: Int64 = 0
    @AppStorage("crossfade") private var crossfade: Double = 0
    @AppStorage("crossfadeAlbums") private var crossfadeAlbums = true
    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var loudness = LoudnessAnalyzer.shared

    var body: some View {
        Form {
            Section("Crossfade") {
                HStack {
                    Toggle("Crossfade songs", isOn: Binding(get: { crossfade > 0 }, set: { crossfade = $0 ? 6 : 0 }))
                    Spacer()
                    Slider(value: $crossfade, in: 1...12, step: 1).frame(width: 180).disabled(crossfade == 0)
                    Text(crossfade > 0 ? "\(Int(crossfade)) s" : "off").monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                Toggle("Not between songs of the same album (keeps live albums seamless)", isOn: $crossfadeAlbums)
                    .disabled(crossfade == 0)
            }
            Section("Sound levelling (ReplayGain)") {
                Picker("Use", selection: $player.replayGainMode) {
                    ForEach(ReplayGainMode.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Preamp")
                    Slider(value: $player.replayGainPreamp, in: -6...6, step: 0.5)
                    Text(String(format: "%+.1f dB", player.replayGainPreamp)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Toggle("Write ReplayGain tags into the files", isOn: $loudness.writeTags)
                Text("Writing tags changes the local files. MP4/M4A files are measured and use iSyncer’s stored ReplayGain values.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    if loudness.running {
                        ProgressView(value: Double(loudness.done), total: Double(max(loudness.total, 1))).frame(width: 160)
                        Text("\(loudness.done) of \(loudness.total)").monospacedDigit()
                        Spacer()
                        Button("Stop") { loudness.cancel() }
                    } else {
                        Text("\(loudness.unanalyzedCount.formatted()) songs not measured yet")
                        Spacer()
                        Button("Analyze Library") { loudness.analyze() }
                            .disabled(loudness.unanalyzedCount == 0)
                    }
                }
                if !loudness.status.isEmpty && !loudness.running {
                    Text(loudness.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Ogg and Opus") {
                Text("macOS can't play Ogg Vorbis or Opus, so iSyncer decodes each one with ffmpeg the first time you play it and keeps a lossless copy (up to 3 GB, oldest dropped first).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if Tools.ffmpeg == nil {
                    Label("Install FFmpeg to play Ogg and Opus, edit tags, analyze loudness, and convert videos.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("Cache: \(Format.bytes(cacheSize))")
                    Spacer()
                    Button("Empty Cache") {
                        try? FileManager.default.removeItem(at: PlaybackCache.folder)
                        measure()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: measure)
    }

    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(at: PlaybackCache.folder,
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        cacheSize = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// How much of a song has to be heard before it scrobbles and counts as played.
@MainActor
private struct ThresholdRow: View {
    @AppStorage("playThreshold") private var threshold: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Scrobble after")
                Slider(value: $threshold, in: 0.1...0.9, step: 0.05)
                Text("\(Int((threshold * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Text("Of the song actually listened to (skipping ahead doesn't count), or 4 minutes, whichever comes first. Also when play counts go up.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
