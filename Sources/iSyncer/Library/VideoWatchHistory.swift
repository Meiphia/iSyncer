import ClassicSync
import Foundation
import SwiftUI

@MainActor
final class VideoWatchHistory: ObservableObject {
    static let shared = VideoWatchHistory()

    struct State: Codable, Equatable {
        var seconds = 0.0
        var duration = 0.0
        var watched = false
        var updated = Date.distantPast

        var fraction: Double { watched ? 1 : duration > 0 ? min(1, seconds / duration) : 0 }
    }

    @Published private(set) var watchedRevision = 0
    @Published private var entries: [String: State] = {
        guard let data = UserDefaults.standard.data(forKey: "videoWatchHistory") else { return [:] }
        return (try? JSONDecoder().decode([String: State].self, from: data)) ?? [:]
    }()

    func state(at url: URL?) -> State {
        guard let url else { return State() }
        return entries[url.standardizedFileURL.path] ?? State()
    }

    func update(_ url: URL, seconds: Double, duration: Double, watched: Bool? = nil) {
        let previous = state(at: url)
        let next = State(seconds: seconds.isFinite ? max(0, seconds) : previous.seconds,
                         duration: duration.isFinite && duration > 0 ? duration : previous.duration,
                         watched: watched ?? previous.watched, updated: Date())
        entries[url.standardizedFileURL.path] = next
        if next.watched != previous.watched { watchedRevision += 1 }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "videoWatchHistory")
        }
    }
}

extension VideoItem {
    var classicTVKey: String {
        Song.videoSyncKey(tv: true, show: show, season: season, episode: episode, title: title)
    }

    static func episodeOrder(_ a: Self, _ b: Self) -> Bool {
        (a.season == 0 ? 1 : 0, a.season, a.episode, a.id) < (b.season == 0 ? 1 : 0, b.season, b.episode, b.id)
    }
}
