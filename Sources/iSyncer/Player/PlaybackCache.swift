import Foundation
import CryptoKit

/// macOS can't decode Ogg Vorbis or Opus, so before playing one the app decodes it with ffmpeg
/// into a lossless ALAC copy in the cache (fast, and no further quality loss). Copies are keyed
/// by path, size and date, and the oldest are dropped once the cache passes its size limit.
@MainActor
final class PlaybackCache {
    static let shared = PlaybackCache()

    nonisolated static let convertedExtensions: Set<String> = ["ogg", "oga", "opus"]
    private let maxBytes: Int64 = 3 * 1024 * 1024 * 1024

    private var waiting: [URL: [(Result<URL, Error>) -> Void]] = [:]

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iSyncer/Playback", isDirectory: true)
    }

    nonisolated static func needsConversion(_ url: URL) -> Bool {
        convertedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func cacheURL(for source: URL) -> URL {
        let v = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(source.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".m4a")
    }

    /// The ready copy, if it's already converted.
    func cachedURL(for source: URL) -> URL? {
        let url = Self.cacheURL(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Touch it, so the size limit drops the least recently played first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    var isConverting: Bool { !waiting.isEmpty }

    /// Converts in the background; `done` runs on the main actor.
    func prepare(_ source: URL, done: @escaping (Result<URL, Error>) -> Void) {
        if let ready = cachedURL(for: source) { done(.success(ready)); return }
        if waiting[source] != nil { waiting[source]?.append(done); return }
        waiting[source] = [done]
        Task {
            let result: Result<URL, Error>
            do {
                result = .success(try await Self.convert(source))
            } catch {
                result = .failure(error)
            }
            let callbacks = waiting.removeValue(forKey: source) ?? []
            for cb in callbacks { cb(result) }
            trim()
        }
    }

    nonisolated private static func convert(_ source: URL) async throws -> URL {
        guard let ffmpeg = Tools.ffmpeg else {
            throw ShellError(message: "Install FFmpeg to play Ogg and Opus files.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = cacheURL(for: source)
        let tmp = folder.appendingPathComponent(".partial-" + UUID().uuidString + ".m4a")
        let r = try await Shell.run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                                            "-i", source.path, "-map", "0:a:0", "-vn",
                                            "-c:a", "alac", "-map_metadata", "-1", tmp.path])
        guard r.ok else {
            try? FileManager.default.removeItem(at: tmp)
            throw ShellError(message: "ffmpeg couldn't decode “\(source.lastPathComponent)”: \(r.stderr.suffix(200))")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func trim() {
        let max = maxBytes
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.folder,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
            var entries = files.compactMap { u -> (URL, Int64, Date)? in
                guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
            }
            var total = entries.reduce(Int64(0)) { $0 + $1.1 }
            guard total > max else { return }
            entries.sort { $0.2 < $1.2 }
            for e in entries where total > max {
                try? fm.removeItem(at: e.0)
                total -= e.1
            }
        }
    }
}
