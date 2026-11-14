import Foundation

/// A set of tag changes. `nil` means "leave as is" (that's how multi-song edits work: only the
/// fields you touched are written). Empty strings / 0 clear a field.
struct TagEdit: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var grouping: String?
    var genre: String?
    var comment: String?
    var year: Int?
    var track: Int?
    var trackTotal: Int?
    var disc: Int?
    var discTotal: Int?
    var bpm: Int?
    var compilation: Bool?
    /// New cover image (JPEG/PNG file), or remove the embedded cover.
    var artwork: URL?
    var removeArtwork = false
    /// Extra free-form tags (e.g. REPLAYGAIN_TRACK_GAIN). MP3 stores them as TXXX frames,
    /// FLAC/Ogg as Vorbis comments. ffmpeg can't write free-form MP4 tags, so they're skipped there.
    var extra: [String: String] = [:]

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil && composer == nil
            && grouping == nil && genre == nil && comment == nil && year == nil && track == nil
            && trackTotal == nil && disc == nil && discTotal == nil && bpm == nil && compilation == nil
            && artwork == nil && !removeArtwork && extra.isEmpty
    }
}

/// Writes tags with ffmpeg in stream-copy mode: the audio is never re-encoded, only the
/// container's tags change. Each file is written to a temporary sibling and swapped in, so a
/// failure never leaves a half-written song behind.
enum TagWriter {
    static let supported: Set<String> = ["mp3", "m4a", "mp4", "aac", "alac", "flac", "ogg", "oga", "opus"]

    static func canEdit(_ url: URL) -> Bool { supported.contains(url.pathExtension.lowercased()) }

    static func write(_ edit: TagEdit, to url: URL) async throws {
        guard let ffmpeg = Tools.ffmpeg else {
            throw ShellError(message: "Install FFmpeg to edit audio tags.")
        }
        let ext = url.pathExtension.lowercased()
        guard supported.contains(ext) else {
            throw ShellError(message: "Tag editing isn't supported for .\(ext) files.")
        }
        let isMP4 = ["m4a", "mp4", "aac", "alac"].contains(ext)
        let isMP3 = ext == "mp3"
        let isOgg = ["ogg", "oga", "opus"].contains(ext)

        // Per-file values for "3 of 12" style fields, so a multi-song edit of the total keeps
        // each song's own number.
        let current = TagReader.read(url: url, wantArtwork: true) ?? TagInfo()
        let keepCover = edit.artwork == nil && !edit.removeArtwork && !isOgg && current.artwork != nil

        var meta: [(String, String)] = []
        func put(_ key: String, _ value: String?) {
            if let value { meta.append((key, value)) }
        }
        put("title", edit.title)
        put("artist", edit.artist)
        put("album", edit.album)
        put("album_artist", edit.albumArtist)
        put("composer", edit.composer)
        put("grouping", edit.grouping)
        put("genre", edit.genre)
        put("comment", edit.comment)
        if let y = edit.year { meta.append(("date", y > 0 ? String(y) : "")) }

        if edit.track != nil || edit.trackTotal != nil {
            let n = edit.track ?? current.track
            let total = edit.trackTotal ?? current.trackTotal
            meta.append(("track", numberString(n, total)))
        }
        if edit.disc != nil || edit.discTotal != nil {
            let n = edit.disc ?? current.disc
            let total = edit.discTotal ?? current.discTotal
            meta.append(("disc", numberString(n, total)))
        }
        if let bpm = edit.bpm {
            let v = bpm > 0 ? String(bpm) : ""
            if isMP3 { meta.append(("TBPM", v)) } else if isMP4 { meta.append(("tmpo", v)) } else { meta.append(("BPM", v)) }
        }
        if let c = edit.compilation {
            if isMP3 { meta.append(("TCMP", c ? "1" : "")) } else if isMP4 { meta.append(("compilation", c ? "1" : "0")) }
            else { meta.append(("COMPILATION", c ? "1" : "")) }
        }

        if !isMP4 {
            for k in edit.extra.keys.sorted() { meta.append((k, edit.extra[k]!)) }
        }

        if isOgg && edit.artwork != nil {
            throw ShellError(message: "Replacing artwork in Ogg/Opus files isn't supported; put a cover.jpg in the album folder instead.")
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".rbsync-edit-\(UUID().uuidString).\(ext)")
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", url.path]
        if let art = edit.artwork { args += ["-i", art.path] }

        args += ["-map", "0:a"]
        if edit.artwork != nil {
            args += ["-map", "1:0"]
        } else if keepCover {
            args += ["-map", "0:v:0"]          // keep the existing embedded cover
        }
        args += ["-c", "copy", "-map_metadata", "0"]
        if edit.artwork != nil || keepCover {
            args += ["-disposition:v", "attached_pic"]
        }
        if isMP3 { args += ["-id3v2_version", "3", "-write_id3v1", "1"] }
        if isMP4 { args += ["-movflags", "+faststart"] }
        for (k, v) in meta { args += ["-metadata", "\(k)=\(v)"] }
        args.append(tmp.path)

        let r = try await Shell.run(ffmpeg, args)
        let fm = FileManager.default
        guard r.ok, fm.fileExists(atPath: tmp.path),
              let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
            try? fm.removeItem(at: tmp)
            let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError(message: "Couldn't write tags to \(url.lastPathComponent): \(detail.prefix(300))")
        }
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }

    private static func numberString(_ n: Int, _ total: Int) -> String {
        if n <= 0 && total <= 0 { return "" }
        return total > 0 ? "\(max(n, 0))/\(total)" : "\(n)"
    }
}
