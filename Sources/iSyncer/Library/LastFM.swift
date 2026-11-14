import Foundation
import AppKit
import CryptoKit
import Security

/// Last.fm scrobbling: songs played in the app, and plays imported from the player at sync.
///
/// Last.fm needs an API account (free, last.fm/api/account/create); its key and shared secret go
/// in Settings → Last.fm. Connecting uses Last.fm's desktop flow: the browser opens to approve the
/// app, then the session key is kept in a private file. Scrobbles wait in a queue on disk until
/// they've been accepted, so nothing is lost offline. Last.fm only takes plays up to 14 days old.
@MainActor
final class LastFM: ObservableObject {
    static let shared = LastFM()

    struct Scrobble: Codable, Hashable, Sendable {
        var artist: String
        var track: String
        var album: String
        var albumArtist: String
        var duration: Int
        var timestamp: Int
    }

    @Published var apiKey = UserDefaults.standard.string(forKey: "lastfm.apiKey") ?? "" {
        didSet { UserDefaults.standard.set(apiKey.trimmingCharacters(in: .whitespaces), forKey: "lastfm.apiKey") }
    }
    @Published var apiSecret = UserDefaults.standard.string(forKey: "lastfm.apiSecret") ?? "" {
        didSet { UserDefaults.standard.set(apiSecret.trimmingCharacters(in: .whitespaces), forKey: "lastfm.apiSecret") }
    }
    @Published var scrobbleApp = UserDefaults.standard.object(forKey: "lastfm.app") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scrobbleApp, forKey: "lastfm.app") }
    }
    @Published var scrobbleDevice = UserDefaults.standard.object(forKey: "lastfm.device") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scrobbleDevice, forKey: "lastfm.device") }
    }
    @Published private(set) var username = UserDefaults.standard.string(forKey: "lastfm.user")
    @Published private(set) var queue: [Scrobble] = []
    @Published private(set) var status = ""
    @Published private(set) var pendingToken: String?
    @Published private(set) var lastSubmitted: Date?

    private var sessionKey: String?
    private var flushTask: Task<Void, Never>?
    private var timer: Timer?
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private var queueFile: URL { LibraryStore.supportFolder.appendingPathComponent("lastfm-queue.json") }

    var isConnected: Bool { sessionKey != nil && hasCredentials }
    var hasCredentials: Bool { !key.isEmpty && !secret.isEmpty }
    private var key: String { apiKey.trimmingCharacters(in: .whitespaces) }
    private var secret: String { apiSecret.trimmingCharacters(in: .whitespaces) }

    private init() {
        sessionKey = CredentialStore.read("lastfm.session")
        if let data = try? Data(contentsOf: queueFile),
           let q = try? JSONDecoder().decode([Scrobble].self, from: data) {
            queue = q
        }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in LastFM.shared.scheduleFlush(after: 0) }
        }
        scheduleFlush(after: 5)
    }

    // MARK: Feeding the queue

    func nowPlaying(_ t: Track) {
        guard scrobbleApp, isConnected, t.duration >= 30, !t.title.isEmpty, !t.artist.isEmpty else { return }
        var params = ["method": "track.updateNowPlaying", "artist": t.artist, "track": t.title]
        if !t.album.isEmpty { params["album"] = t.album }
        if t.duration > 0 { params["duration"] = String(Int(t.duration)) }
        if !t.albumArtist.isEmpty, t.albumArtist != t.artist { params["albumArtist"] = t.albumArtist }
        Task {
            do {
                _ = try await call(params, signed: true, session: true)
                nowPlayingTitle = t.title
            } catch {
                status = "Now playing didn't update: \(error.localizedDescription)"
            }
        }
    }

    /// The song Last.fm currently shows as "Scrobbling now" (for Settings).
    @Published private(set) var nowPlayingTitle: String?

    func scrobble(_ t: Track, at date: Date) {
        guard scrobbleApp else { return }
        add([Self.entry(for: t, at: date.timeIntervalSince1970)])
    }

    /// Timestamped plays imported from a device.
    @discardableResult
    func addDevicePlays(_ plays: [Scrobble]) -> Int {
        scrobbleDevice ? add(plays) : 0
    }

    nonisolated static func entry(for t: Track, at timestamp: Double) -> Scrobble {
        Scrobble(artist: t.artist, track: t.title, album: t.album, albumArtist: t.albumArtist,
                 duration: Int(t.duration), timestamp: Int(timestamp))
    }

    @discardableResult
    private func add(_ items: [Scrobble]) -> Int {
        let oldest = Int(Date().timeIntervalSince1970) - 14 * 86_400
        let fresh = items.filter {
            !$0.artist.isEmpty && !$0.track.isEmpty && ($0.duration == 0 || $0.duration >= 30) && $0.timestamp > oldest
        }
        var seen = Set(queue)
        let added = fresh.filter { seen.insert($0).inserted }
        guard !added.isEmpty else { return 0 }
        queue.append(contentsOf: added)
        queue.sort { $0.timestamp < $1.timestamp }
        save()
        scheduleFlush(after: 3)
        return added.count
    }

    private func save() {
        if let data = try? JSONEncoder().encode(queue) { try? data.write(to: queueFile, options: .atomic) }
    }

    // MARK: Connecting

    /// Step 1: get a token and open Last.fm's approval page.
    func beginConnect() async {
        guard hasCredentials else { status = "Enter your API key and shared secret first."; return }
        do {
            let json = try await call(["method": "auth.getToken"], signed: true, session: false)
            guard let token = json["token"] as? String else { throw ShellError(message: "Last.fm didn't return a token.") }
            pendingToken = token
            status = "Approve iSyncer in your browser, then click Finish."
            if let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(key)&token=\(token)") {
                NSWorkspace.shared.open(url)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    /// Step 2: after approving in the browser, trade the token for a session.
    func finishConnect() async {
        guard let token = pendingToken else { return }
        do {
            let json = try await call(["method": "auth.getSession", "token": token], signed: true, session: false)
            guard let session = json["session"] as? [String: Any], let sk = session["key"] as? String else {
                throw ShellError(message: "Last.fm didn't return a session.")
            }
            sessionKey = sk
            CredentialStore.write("lastfm.session", sk)
            username = session["name"] as? String
            UserDefaults.standard.set(username, forKey: "lastfm.user")
            pendingToken = nil
            status = "Connected."
            scheduleFlush(after: 0)
        } catch {
            status = error.localizedDescription + " (Did you approve it in the browser?)"
        }
    }

    func disconnect() {
        sessionKey = nil
        username = nil
        pendingToken = nil
        CredentialStore.delete("lastfm.session")
        UserDefaults.standard.removeObject(forKey: "lastfm.user")
        status = "Disconnected."
    }

    func clearQueue() {
        queue = []
        save()
    }

    // MARK: Submitting

    func scheduleFlush(after seconds: Double) {
        guard flushTask == nil else { return }
        flushTask = Task {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await flush()
            flushTask = nil
        }
    }

    func flush() async {
        guard isConnected, !queue.isEmpty else { return }
        // Last.fm rejects anything older than 14 days.
        let oldest = Int(Date().timeIntervalSince1970) - 14 * 86_400 + 600
        let before = queue.count
        queue.removeAll { $0.timestamp < oldest }
        if queue.count != before { save() }

        while !queue.isEmpty, isConnected {
            let batch = Array(queue.prefix(50))
            var params = ["method": "track.scrobble"]
            for (i, s) in batch.enumerated() {
                params["artist[\(i)]"] = s.artist
                params["track[\(i)]"] = s.track
                params["timestamp[\(i)]"] = String(s.timestamp)
                if !s.album.isEmpty { params["album[\(i)]"] = s.album }
                if !s.albumArtist.isEmpty, s.albumArtist != s.artist { params["albumArtist[\(i)]"] = s.albumArtist }
                if s.duration > 0 { params["duration[\(i)]"] = String(s.duration) }
            }
            do {
                _ = try await call(params, signed: true, session: true)
                let sent = Set(batch)
                queue.removeAll { sent.contains($0) }
                save()
                lastSubmitted = Date()
                status = "Scrobbled \(batch.count) song\(batch.count == 1 ? "" : "s")."
            } catch let e as APIError {
                status = e.localizedDescription
                if e.code == 9 { disconnect(); status = "Last.fm session expired. Connect again." }
                if e.code == 11 || e.code == 16 || e.code == 29 { return }   // try again later
                // Anything else would fail forever: drop the batch rather than block the queue.
                let sent = Set(batch)
                queue.removeAll { sent.contains($0) }
                save()
            } catch {
                status = "Offline? \(error.localizedDescription)"
                return
            }
        }
    }

    struct APIError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { "Last.fm: \(message) (\(code))" }
    }

    private func call(_ params: [String: String], signed: Bool, session: Bool) async throws -> [String: Any] {
        var p = params
        p["api_key"] = key
        if session {
            guard let sk = sessionKey else { throw APIError(code: 9, message: "Not connected") }
            p["sk"] = sk
        }
        if signed {
            let base = p.keys.sorted().map { $0 + p[$0]! }.joined() + secret
            p["api_sig"] = Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        p["format"] = "json"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("iSyncer/0.2", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = p.map { k, v in
            (k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k) + "=" +
            (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShellError(message: "Last.fm sent something unexpected.")
        }
        if let code = json["error"] as? Int {
            throw APIError(code: code, message: json["message"] as? String ?? "error")
        }
        return json
    }
}

/// Stores service credentials in the Keychain. Moves over the plain file that
/// earlier builds used.
@MainActor
enum CredentialStore {
    private static let service = "com.jaz.isyncer"
    private static var legacyFile: URL { LibraryStore.supportFolder.appendingPathComponent("credentials.json") }

    static func read(_ account: String) -> String? {
        migrate()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecAttrLabel as String: "iSyncer (\(account))",
                                kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    private static func migrate() {
        guard let data = try? Data(contentsOf: legacyFile),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (k, v) in d { write(k, v) }
        try? FileManager.default.removeItem(at: legacyFile)
    }
}
