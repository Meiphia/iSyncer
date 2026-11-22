import ClassicSync
import CryptoKit
import Foundation

enum ClassicVideoConversion {
    static func cachedVideo(for url: URL, size: Int, date: Date, profile: String, in cache: URL) -> URL {
        let identity = "\(profile)\0\(url.path)\0\(size)\0\(date.timeIntervalSinceReferenceDate)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return cache.appending(path: key + ".mp4")
    }

    static func transferIdentity(for url: URL, size: Int, date: Date, in cache: URL) -> EpisodeTransferIdentity {
        let profiles = ["mpeg4-simple-aligned-v2", "mpeg4-simple-v1"]
        return EpisodeTransferIdentity(sources: [url] + profiles.map {
            cachedVideo(for: url, size: size, date: date, profile: $0, in: cache)
        }, date: date)
    }

    static func prepare(_ video: ClassicVideo, cache: ConversionCache, threads: Int = 2) async throws -> Song {
        if let original = try? await LibraryScanner.scanVideo(video) { return original }
        try cache.checkAvailable()
        let values = try video.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                            .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let date = values.contentModificationDate else {
            throw SyncError("Cannot read the source video.")
        }
        let output = cachedVideo(for: video.url, size: size, date: date, profile: "mpeg4-simple-aligned-v2", in: cache.video)
        // Derive iPod paths using the original default cache location, even for a custom cache.
        let defaultVideoCache = ConversionCache.defaultVideo(in: cache.defaultFolder)
        let transferURL = defaultVideoCache.appendingPathComponent(output.lastPathComponent)
        let cachedPrevious = cachedVideo(for: video.url, size: size, date: date, profile: "mpeg4-simple-v1", in: cache.video)
        let previous = FileManager.default.fileExists(atPath: cachedPrevious.path)
            ? cachedPrevious : defaultVideoCache.appendingPathComponent(cachedPrevious.lastPathComponent)
        func scan(_ url: URL) async throws -> Song {
            let song = try await LibraryScanner.scanVideo(.init(url: url, title: video.title, show: video.show,
                                                     season: video.season, episode: video.episode, year: video.year),
                                               converted: true, metadataSource: video.url)
            return song.usingVideoEncoding(transferURL: transferURL, previousURL: previous)
        }
        if let cached = try? await scan(output) { return cached }
        guard let ffmpeg = Tools.ffmpeg else { throw SyncError("Video conversion requires FFmpeg.") }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: cache.video, withIntermediateDirectories: true)
        let temporary = cache.video.appending(path: ".\(UUID()).mp4")
        defer { try? fm.removeItem(at: temporary) }
        let result = try await Shell.run(ffmpeg, [
            "-nostdin", "-loglevel", "error", "-threads", String(threads), "-filter_threads", "1", "-i", video.url.path,
            "-map", "0:v:0", "-map", "0:a:0", "-map_chapters", "-1",
            "-vf", "scale=w=min(640\\,iw):h=min(480\\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=ceil(iw/16)*16:ceil(ih/16)*16:(ow-iw)/2:(oh-ih)/2",
            "-fpsmax", "30", "-fps_mode", "cfr", "-c:v", "mpeg4", "-profile:v", "0", "-pix_fmt", "yuv420p", "-bf", "0",
            "-b:v", "850k", "-maxrate", "1200k", "-bufsize", "1200k", "-g", "30",
            "-c:a", "aac", "-profile:a", "aac_low", "-b:a", "112k", "-ar", "44100", "-ac", "2",
            "-threads:v", String(threads), "-movflags", "+faststart", temporary.path
        ])
        try Task.checkCancellation()
        guard result.ok else { throw SyncError("Could not convert \(video.title): \(result.stderr)") }
        _ = try await scan(temporary)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temporary, to: output)
        }
        return try await scan(output)
    }
}
