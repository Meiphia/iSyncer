import Darwin
import Foundation
import SwiftUI

@MainActor
final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()
    private let ipc = DiscordIPC()
    private var last: String?
    private var refreshed = Date.distantPast
    private var coverLookup: Task<Void, Never>?
    @Published private(set) var coverURL: URL?
    @Published private(set) var coverStatus: String?
    private var artwork: DiscordAlbumArt.Artwork?
    private var renewCoverAt: Date?

    func update(track: Track?, playing: Bool, position: Double, duration: Double) {
        let defaults = UserDefaults.standard
        let client = defaults.string(forKey: "discordApplicationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let category = track?.podcastShow != nil ? "discordPodcasts" : track?.audiobookTitle != nil ? "discordAudiobooks" : "discordMusic"
        guard defaults.bool(forKey: "discordEnabled"), UInt64(client) != nil,
              defaults.object(forKey: category) as? Bool ?? (category == "discordMusic"),
              playing, let track else {
            clear()
            return
        }
        let now = Date()
        let start = now.timeIntervalSince1970 - position
        let key = "\(client)|\(track.id)"
        let changedTrack = last != key
        if changedTrack || (coverLookup == nil && renewCoverAt.map { $0 <= now } == true) {
            coverLookup?.cancel()
            if changedTrack {
                coverURL = nil
                artwork = nil
                coverStatus = nil
            }
            renewCoverAt = nil
            if category == "discordMusic", defaults.object(forKey: "discordAlbumArt") as? Bool ?? true {
                coverStatus = "Preparing artwork for \(track.album)…"
                let relayEnabled = defaults.bool(forKey: "discordLocalArtwork")
                let relayOrigin = defaults.string(forKey: "discordArtworkRelayURL") ?? ""
                coverLookup = Task {
                    var result = await DiscordAlbumArt.shared.lookup(
                        albumArtist: track.albumArtist, artist: track.artist, album: track.album
                    )
                    guard !Task.isCancelled, last == key else { return }
                    var relayFailure: String?
                    var renewAt: Date?
                    if result == nil, relayEnabled {
                        do {
                            if let image = await ArtworkLoader.shared.image(for: track) {
                                try Task.checkCancellation()
                                let cover = try await DiscordArtworkRelay.publish(
                                    DiscordArtworkRelay.thumbnail(image), customOrigin: relayOrigin
                                )
                                result = .init(image: cover.url)
                                renewAt = cover.renewAt
                            }
                        } catch {
                            relayFailure = error.localizedDescription
                        }
                    }
                    guard !Task.isCancelled, last == key else { return }
                    coverLookup = nil
                    renewCoverAt = renewAt
                    let status = renewAt != nil ? "Local cover fallback sent to Discord."
                        : result != nil ? "Catalog cover sent to Discord."
                        : "No public cover found for \(track.album)."
                    coverStatus = [relayFailure, status].compactMap { $0 }.joined(separator: " ")
                    artwork = result
                    coverURL = result?.image
                    refresh()
                    PlayerEngine.shared.refreshDiscordPresence()
                }
            }
        }
        guard last != key || now.timeIntervalSince(refreshed) >= 15 else { return }
        last = key
        refreshed = now
        let activity = Self.activity(track: track, start: start, position: position, duration: duration, cover: artwork)
        ipc.send(client: client, activity: activity)
    }

    static func activity(track: Track, start: Double, position: Double, duration: Double, cover: DiscordAlbumArt.Artwork?) -> [String: Any] {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let credit = artist.isEmpty ? track.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines) : artist
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        var activity: [String: Any] = [
            "type": 2,
            "details": clipped(track.title)
        ]
        if !credit.isEmpty {
            activity["state"] = clipped(credit)
            activity["status_display_type"] = 1
        } else {
            activity["status_display_type"] = 2
        }
        if let cover {
            var assets = ["large_image": cover.image.absoluteString]
            let label = album.isEmpty ? track.title.trimmingCharacters(in: .whitespacesAndNewlines) : album
            if label.count >= 2 {
                assets["large_text"] = clipped(label)
            } else if !label.isEmpty, !credit.isEmpty {
                assets["large_text"] = clipped("\(label) · \(credit)")
            }
            if let page = cover.albumPage {
                assets["large_url"] = page.absoluteString
                activity["buttons"] = [["label": "View on Apple Music", "url": page.absoluteString]]
            }
            activity["assets"] = assets
        }
        if start.isFinite, duration.isFinite, position.isFinite, duration > 0, position >= 0, position < duration {
            activity["timestamps"] = ["start": Int(start), "end": Int(start + duration)]
        }
        return activity
    }

    func clear() {
        guard last != nil else { return }
        last = nil
        coverLookup?.cancel()
        coverLookup = nil
        renewCoverAt = nil
        coverURL = nil
        artwork = nil
        coverStatus = nil
        ipc.send(client: nil, activity: nil)
    }

    func refresh() { refreshed = .distantPast }

    private static func clipped(_ input: String) -> String {
        String(String.UnicodeScalarView(input.unicodeScalars.prefix(100)))
    }
}

private final class DiscordIPC: @unchecked Sendable {
    private let queue = DispatchQueue(label: "iSyncer.DiscordIPC")
    private var fd: Int32 = -1
    private var appID: String?
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var ready = false
    private var pending: Data?

    func send(client: String?, activity: [String: Any]?) {
        let command: [String: Any] = ["cmd": "SET_ACTIVITY", "nonce": UUID().uuidString,
                                     "args": ["pid": getpid(), "activity": activity as Any? ?? NSNull()]]
        guard let body = try? JSONSerialization.data(withJSONObject: command) else { return }
        queue.async {
            guard let client else {
                if self.ready { _ = self.write(1, body) }
                self.closeConnection()
                return
            }
            if self.appID != client { self.closeConnection() }
            self.pending = body
            if self.fd < 0 { self.connect(client) }
            else if self.ready, !self.write(1, body) { self.closeConnection() }
        }
    }

    private func connect(_ client: String) {
        let environment = ProcessInfo.processInfo.environment
        let folders = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] } + ["/tmp"]
        for folder in folders where !folder.isEmpty {
            for index in 0..<10 {
                let path = URL(fileURLWithPath: folder).appendingPathComponent("discord-ipc-\(index)").path
                var address = sockaddr_un()
                let bytes = Data(path.utf8) + Data([0])
                guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { continue }
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { destination in
                    destination.copyBytes(from: bytes)
                }
                let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
                guard candidate >= 0 else { continue }
                var noSignal: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if result != 0 { Darwin.close(candidate); continue }
                fd = candidate
                appID = client
                let reader = DispatchSource.makeReadSource(fileDescriptor: candidate, queue: queue)
                reader.setEventHandler { [weak self] in self?.read() }
                reader.setCancelHandler { Darwin.close(candidate) }
                readSource = reader
                reader.resume()
                let hello = try? JSONSerialization.data(withJSONObject: ["v": 1, "client_id": client])
                if let hello, write(0, hello) {
                    queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, self.fd == candidate, !self.ready else { return }
                        self.closeConnection()
                    }
                } else { closeConnection() }
                return
            }
        }
    }

    private func write(_ op: UInt32, _ body: Data) -> Bool {
        var header = [op.littleEndian, UInt32(body.count).littleEndian]
        let frame = header.withUnsafeMutableBytes { Data($0) } + body
        return frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, base + sent, bytes.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let size = Darwin.recv(fd, &bytes, bytes.count, 0)
        guard size > 0 else { closeConnection(); return }
        buffer.append(contentsOf: bytes.prefix(size))
        while buffer.count >= 8 {
            let header = buffer.prefix(8)
            let op = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
            guard length <= 1_048_576 else { closeConnection(); return }
            guard buffer.count >= length + 8 else { return }
            let body = Data(buffer.dropFirst(8).prefix(length))
            buffer.removeFirst(length + 8)
            if op == 2 { closeConnection(); return }
            if op == 3, !write(4, body) { closeConnection(); return }
            if op == 1, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               json["evt"] as? String == "READY" {
                ready = true
                if let pending, !write(1, pending) { closeConnection(); return }
            }
        }
    }

    private func closeConnection() {
        readSource?.cancel()
        readSource = nil
        fd = -1
        appID = nil
        ready = false
        buffer.removeAll()
        pending = nil
    }
}

struct DiscordSettings: View {
    @ObservedObject private var presence = DiscordPresence.shared
    @AppStorage("discordEnabled") private var enabled = false
    @AppStorage("discordApplicationID") private var client = ""
    @AppStorage("discordMusic") private var music = true
    @AppStorage("discordPodcasts") private var podcasts = false
    @AppStorage("discordAudiobooks") private var audiobooks = false
    @AppStorage("discordAlbumArt") private var albumArt = true
    @AppStorage("discordLocalArtwork") private var localArtwork = false
    @AppStorage("discordArtworkRelayURL") private var relayURL = ""
    @State private var relayToken = ""
    @State private var showRelaySettings = false

    var body: some View {
        Form {
            Toggle("Share Now Playing on Discord", isOn: $enabled)
            TextField("Discord Application ID", text: $client)
            Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            Text("Create an application named iSyncer, copy its Application ID, and leave the Discord desktop app open.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Music", isOn: $music)
            Toggle("Podcasts", isOn: $podcasts)
            Toggle("Audiobooks", isOn: $audiobooks)
            Toggle("Show album artwork for music", isOn: $albumArt)
            Text("Searches Apple Music and MusicBrainz by Album Artist, then Artist.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Share artwork from my music files", isOn: $localArtwork)
                .disabled(!albumArt)
            if localArtwork && albumArt {
                Text("When the catalog search finds no cover, iSyncer shares a temporary thumbnail for Discord.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $showRelaySettings) {
                    TextField("Custom Relay URL", text: $relayURL)
                    SecureField("Custom Relay Token", text: $relayToken)
                    Button("Save Relay Token") {
                        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if token.isEmpty { CredentialStore.delete("discord.artworkRelayToken") }
                        else { CredentialStore.write("discord.artworkRelayToken", token) }
                        presence.clear()
                        PlayerEngine.shared.refreshDiscordPresence()
                    }
                    Text("Leave the URL blank to use the iSyncer relay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let status = presence.coverStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let url = presence.coverURL {
                Link("Open Cover Sent to Discord", destination: url)
            }
        }
        .formStyle(.grouped)
        .onAppear { relayToken = CredentialStore.read("discord.artworkRelayToken") ?? "" }
        .onChange(of: [String(enabled), client, String(music), String(podcasts), String(audiobooks), String(albumArt), String(localArtwork), relayURL]) {
            DiscordPresence.shared.clear()
            PlayerEngine.shared.refreshDiscordPresence()
        }
    }
}
