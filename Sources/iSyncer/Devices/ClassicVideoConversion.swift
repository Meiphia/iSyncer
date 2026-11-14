import ClassicSync
import CryptoKit
import Foundation

enum ClassicVideoConversion {
    static func prepare(_ video: ClassicVideo, cache: URL) async throws -> Song {
        if let original = try? await LibraryScanner.scanVideo(video) { return original }
        guard let ffmpeg = Tools.ffmpeg else { throw SyncError("Video conversion requires FFmpeg.") }
        let values = try video.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                            .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let date = values.contentModificationDate else {
            throw SyncError("Cannot read the source video.")
        }
        func cachedVideo(_ profile: String) -> URL {
            let identity = "\(profile)\0\(video.url.path)\0\(size)\0\(date.timeIntervalSinceReferenceDate)"
            let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return cache.appending(path: key + ".mp4")
        }
        let output = cachedVideo("mpeg4-simple-aligned-v2")
        let previous = cachedVideo("mpeg4-simple-v1")
        func scan(_ url: URL) async throws -> Song {
            let song = try await LibraryScanner.scanVideo(.init(url: url, title: video.title, show: video.show,
                                                     season: video.season, episode: video.episode, year: video.year),
                                               converted: true, metadataSource: video.url)
            return song.replacingVideoEncoding(at: previous)
        }
        if let cached = try? await scan(output) { return cached }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let temporary = cache.appending(path: ".\(UUID()).mp4")
        defer { try? fm.removeItem(at: temporary) }
        let result = try await Shell.run(ffmpeg, [
            "-nostdin", "-loglevel", "error", "-i", video.url.path,
            "-map", "0:v:0", "-map", "0:a:0", "-map_chapters", "-1",
            "-vf", "scale=w=min(640\\,iw):h=min(480\\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=ceil(iw/16)*16:ceil(ih/16)*16:(ow-iw)/2:(oh-ih)/2",
            "-fpsmax", "30", "-fps_mode", "cfr", "-c:v", "mpeg4", "-profile:v", "0", "-pix_fmt", "yuv420p", "-bf", "0",
            "-b:v", "850k", "-maxrate", "1200k", "-bufsize", "1200k", "-g", "30",
            "-c:a", "aac", "-profile:a", "aac_low", "-b:a", "112k", "-ar", "44100", "-ac", "2",
            "-movflags", "+faststart", temporary.path
        ])
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
