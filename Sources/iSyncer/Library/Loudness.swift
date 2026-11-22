import Foundation

/// ReplayGain analysis. Each song's loudness is measured with ffmpeg's EBU R128 meter
/// (ReplayGain 2.0: gain = −18 LUFS − measured loudness), albums are combined from their
/// songs, and the results are stored in the library (the player uses them) and, if wanted,
/// written into the files as REPLAYGAIN_* tags so Rockbox can level the volume too.
@MainActor
final class LoudnessAnalyzer: ObservableObject {
    static let shared = LoudnessAnalyzer()

    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var status = ""
    @Published var writeTags = UserDefaults.standard.object(forKey: "rgWriteTags") as? Bool ?? true {
        didSet { UserDefaults.standard.set(writeTags, forKey: "rgWriteTags") }
    }
    private var task: Task<Void, Never>?

    private var library: LibraryStore { LibraryStore.shared }

    /// Songs in the library without ReplayGain values yet.
    var unanalyzedCount: Int { library.tracks.filter { $0.rgTrackGain == nil }.count }

    func cancel() {
        task?.cancel()
    }

    /// Analyzes the given songs, or every song without values when `ids` is nil. Whole albums
    /// are always measured together, so album gain is right.
    func analyze(_ ids: [String]? = nil) {
        guard !running, let root = library.libraryRoot else { return }
        guard Tools.ffmpeg != nil else {
            status = "Install FFmpeg to measure loudness."
            return
        }
        let all = library.tracks
        let wanted: Set<String> = ids.map(Set.init) ?? Set(all.filter { $0.rgTrackGain == nil }.map(\.id))
        guard !wanted.isEmpty else { status = "Every song already has ReplayGain values."; return }

        // Group whole albums (folder + album name) that contain any wanted song.
        func albumKey(_ t: Track) -> String {
            t.album.isEmpty ? "\u{1}" + t.id : (t.id as NSString).deletingLastPathComponent + "\u{1}" + t.album
        }
        let keys = Set(all.filter { wanted.contains($0.id) }.map(albumKey))
        var albums: [String: [Track]] = [:]
        for t in all where keys.contains(albumKey(t)) { albums[albumKey(t), default: []].append(t) }
        let groups = albums.values.map { $0 }
        let jobs = groups.flatMap { $0 }

        running = true
        done = 0
        total = jobs.count
        status = "Measuring loudness…"
        let write = writeTags
        task = Task {
            var measured: [String: (lufs: Double, peak: Double, duration: Double)] = [:]
            var remaining = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.offset, $0.element.count) })
            let groupOf = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { g in g.element.map { ($0.id, g.offset) } })
            var pendingRefresh: [String] = []
            var failures = 0

            await withTaskGroup(of: (String, (Double, Double)?).self) { pool in
                var next = 0
                func add() {
                    guard next < jobs.count, !Task.isCancelled else { return }
                    let t = jobs[next]
                    next += 1
                    let url = root.appendingLibraryPath(t.id)
                    pool.addTask { (t.id, await Self.measure(url)) }
                }
                for _ in 0..<4 { add() }
                for await (id, result) in pool {
                    done += 1
                    if let (lufs, peak) = result, let t = library.track(id) {
                        measured[id] = (lufs, peak, max(t.duration, 1))
                    } else {
                        failures += 1
                    }
                    if let g = groupOf[id] {
                        remaining[g, default: 1] -= 1
                        if remaining[g] == 0 {
                            let ids = groups[g].map(\.id)
                            let values = Self.combine(ids.compactMap { i in measured[i].map { (i, $0) } })
                            library.setLoudness(values)
                            if write {
                                status = "Writing ReplayGain tags…"
                                await Self.writeTags(values, root: root)
                                pendingRefresh += values.keys
                                if pendingRefresh.count >= 150 {
                                    await library.refresh(pendingRefresh)
                                    pendingRefresh = []
                                }
                            }
                            status = "Measuring loudness…"
                        }
                    }
                    add()
                }
            }
            if !pendingRefresh.isEmpty { await library.refresh(pendingRefresh) }
            running = false
            let cancelled = Task.isCancelled
            status = (cancelled ? "Stopped after \(done) songs." : "Done: \(done) songs.")
                + (failures > 0 ? " \(failures) couldn't be read." : "")
        }
    }

    /// Integrated loudness (LUFS) and sample peak (linear) of one file.
    nonisolated static func measure(_ url: URL) async -> (Double, Double)? {
        // Files that already carry ReplayGain tags don't need decoding.
        if let info = TagReader.read(url: url), let g = info.rgTrackGain {
            return (-18 - g, info.rgTrackPeak ?? 1)
        }
        guard let ffmpeg = Tools.ffmpeg else { return nil }
        guard let r = try? await Shell.run(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", url.path,
                                                    "-map", "0:a:0", "-af", "ebur128=peak=sample:framelog=quiet",
                                                    "-f", "null", "-"]) else { return nil }
        let text = r.stderr
        guard let sumRange = text.range(of: "Summary:", options: .backwards) else { return nil }
        let summary = text[sumRange.upperBound...]
        func value(after label: String) -> Double? {
            guard let lr = summary.range(of: label) else { return nil }
            let rest = summary[lr.upperBound...].trimmingCharacters(in: .whitespaces)
            let num = rest.prefix { "-+.0123456789".contains($0) || $0 == "i" || $0 == "n" || $0 == "f" }
            return Double(num)
        }
        guard let lufs = value(after: "I:"), lufs.isFinite, lufs > -70 else { return nil }
        let peakDB = value(after: "Peak:") ?? 0
        return (lufs, pow(10, peakDB / 20))
    }

    /// Track and album ReplayGain 2.0 values for one album's songs.
    nonisolated static func combine(_ songs: [(String, (lufs: Double, peak: Double, duration: Double))]) -> [String: AudioProcessor.Gains] {
        guard !songs.isEmpty else { return [:] }
        // Album loudness: duration-weighted energy mean of the songs.
        let energy = songs.reduce(0.0) { $0 + $1.1.duration * pow(10, $1.1.lufs / 10) }
        let seconds = songs.reduce(0.0) { $0 + $1.1.duration }
        let albumLUFS = 10 * log10(energy / seconds)
        let albumPeak = songs.map { $0.1.peak }.max() ?? 1
        var out: [String: AudioProcessor.Gains] = [:]
        for (id, m) in songs {
            out[id] = AudioProcessor.Gains(track: (-18 - m.lufs).rounded2, album: (-18 - albumLUFS).rounded2,
                                           trackPeak: m.peak, albumPeak: albumPeak)
        }
        return out
    }

    nonisolated private static func writeTags(_ values: [String: AudioProcessor.Gains], root: URL) async {
        for (id, g) in values {
            let url = root.appendingLibraryPath(id)
            guard TagWriter.canEdit(url), !["m4a", "mp4", "aac", "alac"].contains(url.pathExtension.lowercased()),
                  let tg = g.track, let ag = g.album,
                  TagReader.read(url: url)?.rgTrackGain == nil else { continue }
            var edit = TagEdit()
            edit.extra = [
                "REPLAYGAIN_TRACK_GAIN": String(format: "%.2f dB", tg),
                "REPLAYGAIN_TRACK_PEAK": String(format: "%.6f", g.trackPeak ?? 1),
                "REPLAYGAIN_ALBUM_GAIN": String(format: "%.2f dB", ag),
                "REPLAYGAIN_ALBUM_PEAK": String(format: "%.6f", g.albumPeak ?? 1),
            ]
            try? await TagWriter.write(edit, to: url)
        }
    }
}

private extension Double {
    var rounded2: Double { (self * 100).rounded() / 100 }
}
