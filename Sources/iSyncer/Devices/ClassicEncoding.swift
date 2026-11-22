import ClassicSync
import CryptoKit
import Foundation

enum ClassicEncoding {
    static let bitrates = AudioTransferSource.aacBitrates

    static var defaultJobs: Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Starts one replacement job as each task completes. Results retain input order.
    static func prepare<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], jobs: Int, operation: @escaping @Sendable (Input) async -> Output,
        progress: (Int, Int) async -> Void
    ) async throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            let width = min(inputs.count, max(1, jobs))
            var results = [Output?](repeating: nil, count: inputs.count)
            for index in 0..<width {
                group.addTask { (index, await operation(inputs[index])) }
            }
            var queued = width
            var completed = 0
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                results[index] = result
                if queued < inputs.count {
                    let next = queued
                    group.addTask { (next, await operation(inputs[next])) }
                    queued += 1
                }
                completed += 1
                await progress(completed, inputs.count)
            }
            return results.compactMap { $0 }
        }
    }

    static func audio(_ track: Track, source: URL, bitrate: Int, cache: URL) async throws -> Song {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let date = values.contentModificationDate else {
            throw SyncError("Cannot read the source audio.")
        }
        let stamp = AudioTransferSource(url: source, size: size, date: date)
        let identity = stamp.aacIdentity(bitrate: bitrate)
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let output = cache.appending(path: key + ".m4a")
        func scan(_ url: URL) async throws -> Song {
            let result = try await LibraryScanner.scanFiles([url])
            guard let song = result.songs.first else {
                throw SyncError(result.failures?.first?.reason ?? "The AAC copy is unreadable.")
            }
            return song.usingAudioSource(stamp, bitrate: bitrate, title: track.title, artist: track.artist,
                                        album: track.album, albumArtist: track.albumArtist, genre: track.genre,
                                        year: track.year, number: track.trackNumber, disc: track.discNumber)
        }
        if let cached = try? await scan(output) { return cached }
        guard let ffmpeg = Tools.ffmpeg else { throw SyncError("AAC conversion requires FFmpeg.") }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let temporary = cache.appending(path: ".\(UUID()).m4a")
        defer { try? fm.removeItem(at: temporary) }
        let result = try await Shell.run(ffmpeg, [
            "-nostdin", "-loglevel", "error", "-threads", "1", "-filter_threads", "1", "-i", source.path,
            "-map", "0:a:0", "-map_metadata", "0", "-map_chapters", "-1",
            "-c:a", "aac", "-profile:a", "aac_low", "-b:a", "\(bitrate)k", "-ar", "44100", "-ac", "2",
            "-threads", "1", "-movflags", "+faststart", temporary.path
        ])
        try Task.checkCancellation()
        guard result.ok else { throw SyncError(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        _ = try await scan(temporary)
        guard try stamp.isCurrent() else { throw SyncError("The source changed during AAC conversion.") }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
        if let artwork = TagReader.read(url: source, wantArtwork: true)?.artwork {
            try? artwork.write(to: output.appendingPathExtension("cover"), options: .atomic)
        }
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temporary, to: output)
        }
        return try await scan(output)
    }

    static func shouldEncode(_ track: Track) -> Bool {
        ["ALAC", "FLAC"].contains(track.codec.uppercased()) || ["alac", "flac"].contains(track.fileExtension)
    }
}
