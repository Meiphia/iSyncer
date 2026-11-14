import Foundation

enum MP4Reader {
    private struct Atom {
        let type: String
        let start: Int     // offset of the atom header within the buffer
        let dataStart: Int // offset of the payload
        let end: Int
    }

    static func read(_ file: FileReader, wantArtwork: Bool) -> TagInfo? {
        // Locate the top-level moov atom (it may be at the end of the file).
        var offset: Int64 = 0
        var moov: [UInt8]?
        var atoms = 0
        while offset + 8 <= file.size && atoms < 1024 {
            let h = file.read(at: offset, count: 16)
            guard h.count >= 8 else { break }
            var size = Int64(h.u32be(0))
            let type = h.latin1(4, 4)
            var headerLen: Int64 = 8
            if size == 1 { size = Int64(bitPattern: h.u64be(8)); headerLen = 16 }
            if size == 0 { size = file.size - offset }
            guard size >= headerLen else { break }
            if type == "moov" {
                guard size < 256 * 1024 * 1024 else { return nil }
                moov = file.read(at: offset, count: Int(size))
                break
            }
            offset += size
            atoms += 1
        }
        guard let m = moov else { return nil }

        var info = TagInfo()
        info.codec = "AAC"

        let top = children(m, from: 0, to: m.count)
        guard let moovAtom = top.first(where: { $0.type == "moov" }) else { return nil }
        let moovKids = children(m, from: moovAtom.dataStart, to: moovAtom.end)

        if let mvhd = moovKids.first(where: { $0.type == "mvhd" }) {
            let d = mvhd.dataStart
            let version = m.u8(d)
            let timescale: Int
            let duration: Double
            if version == 1 {
                timescale = m.u32be(d + 20)
                duration = Double(m.u64be(d + 24))
            } else {
                timescale = m.u32be(d + 12)
                duration = Double(m.u32be(d + 16))
            }
            if timescale > 0 { info.duration = duration / Double(timescale) }
        }

        // Codec + sample rate: trak/mdia/minf/stbl/stsd
        for trak in moovKids where trak.type == "trak" {
            guard let stsd = find(m, in: trak, path: ["mdia", "minf", "stbl", "stsd"]) else { continue }
            let entry = stsd.dataStart + 8         // full box (4) + entry count (4)
            let format = m.latin1(entry + 4, 4)
            if format == "alac" {
                info.codec = "ALAC"
                info.lossless = true
            } else if format == "mp4a" {
                info.codec = "AAC"
            } else {
                continue
            }
            info.sampleRate = m.u32be(entry + 8 + 24) >> 16
            break
        }

        // Tags: udta/meta/ilst
        if let udta = moovKids.first(where: { $0.type == "udta" }),
           let meta = children(m, from: udta.dataStart, to: udta.end).first(where: { $0.type == "meta" }) {
            // meta is a full box: skip version/flags. Some writers omit them; detect that.
            var metaStart = meta.dataStart + 4
            if m.latin1(meta.dataStart + 4, 4) == "hdlr" { metaStart = meta.dataStart }
            if let ilst = children(m, from: metaStart, to: meta.end).first(where: { $0.type == "ilst" }) {
                for item in children(m, from: ilst.dataStart, to: ilst.end) {
                    guard let data = children(m, from: item.dataStart, to: item.end).first(where: { $0.type == "data" }) else { continue }
                    let valueStart = data.dataStart + 8   // type indicator + locale
                    let valueLen = data.end - valueStart
                    guard valueLen >= 0 else { continue }
                    let string = { m.utf8(valueStart, valueLen).trimmingCharacters(in: .whitespacesAndNewlines) }
                    switch item.type {
                    case "\u{A9}lyr":
                        if valueLen <= Lyrics.maximumSize { info.lyrics = string() }
                    case "\u{A9}nam": info.title = string()
                    case "\u{A9}ART": info.artist = string()
                    case "aART": info.albumArtist = string()
                    case "\u{A9}alb": info.album = string()
                    case "\u{A9}gen": info.genre = string()
                    case "gnre":
                        if info.genre.isEmpty { info.genre = TagReader.genreName(index: m.u16be(valueStart) - 1) }
                    case "\u{A9}day": info.year = TagReader.parseYear(string())
                    case "trkn":
                        info.track = m.u16be(valueStart + 2)
                        info.trackTotal = m.u16be(valueStart + 4)
                    case "disk":
                        info.disc = m.u16be(valueStart + 2)
                        info.discTotal = m.u16be(valueStart + 4)
                    case "\u{A9}wrt": info.composer = string()
                    case "\u{A9}grp": info.grouping = string()
                    case "\u{A9}cmt": info.comment = string()
                    case "tmpo": info.bpm = m.u16be(valueStart)
                    case "cpil": info.compilation = m.u8(valueStart) != 0
                    case "----":
                        // iTunes freeform: mean / name / data
                        if let name = children(m, from: item.dataStart, to: item.end).first(where: { $0.type == "name" }),
                           name.end - name.dataStart > 4 {
                            let key = m.utf8(name.dataStart + 4, name.end - name.dataStart - 4)
                            if key.uppercased().hasPrefix("REPLAYGAIN_") {
                                TagReader.applyReplayGain(key, string(), to: &info)
                            }
                        }
                    case "covr":
                        if wantArtwork, info.artwork == nil, valueLen > 0 {
                            info.artwork = Data(m.bytes(valueStart, valueLen))
                        }
                    default: break
                    }
                }
            }
        }
        return info
    }

    private static func children(_ b: [UInt8], from start: Int, to end: Int) -> [Atom] {
        var out: [Atom] = []
        var o = start
        while o + 8 <= end && o + 8 <= b.count {
            var size = b.u32be(o)
            let type = b.latin1(o + 4, 4)
            var header = 8
            if size == 1 { size = Int(truncatingIfNeeded: b.u64be(o + 8)); header = 16 }
            if size == 0 { size = end - o }
            guard size >= header, o + size <= end else { break }
            out.append(Atom(type: type, start: o, dataStart: o + header, end: o + size))
            o += size
        }
        return out
    }

    private static func find(_ b: [UInt8], in atom: Atom, path: [String]) -> Atom? {
        var current = atom
        for name in path {
            guard let next = children(b, from: current.dataStart, to: current.end).first(where: { $0.type == name }) else {
                return nil
            }
            current = next
        }
        return current
    }
}

enum RIFFReader {
    static func readWAV(_ file: FileReader, wantArtwork: Bool) -> TagInfo? {
        let head = file.read(at: 0, count: 12)
        guard head.matches("RIFF", at: 0), head.matches("WAVE", at: 8) else { return nil }
        var info = TagInfo()
        info.codec = "WAV"
        info.lossless = true
        var offset: Int64 = 12
        var byteRate = 0
        var dataSize = 0
        var chunks = 0
        while offset + 8 <= file.size && chunks < 256 {
            let h = file.read(at: offset, count: 8)
            guard h.count == 8 else { break }
            let id = h.latin1(0, 4)
            let size = h.u32le(4)
            if id == "fmt " {
                let f = file.read(at: offset + 8, count: 16)
                info.sampleRate = f.u32le(4)
                byteRate = f.u32le(8)
            } else if id == "data" {
                dataSize = size
            } else if id.lowercased() == "id3 " {
                let tag = file.read(at: offset + 8, count: size)
                ID3v2.parse(tag, into: &info, wantArtwork: wantArtwork)
            }
            offset += 8 + Int64(size) + Int64(size & 1)
            chunks += 1
        }
        if byteRate > 0 { info.duration = Double(dataSize) / Double(byteRate) }
        return info
    }

    static func readAIFF(_ file: FileReader, wantArtwork: Bool) -> TagInfo? {
        let head = file.read(at: 0, count: 12)
        guard head.matches("FORM", at: 0), head.matches("AIFF", at: 8) || head.matches("AIFC", at: 8) else { return nil }
        var info = TagInfo()
        info.codec = "AIFF"
        info.lossless = true
        var offset: Int64 = 12
        var chunks = 0
        while offset + 8 <= file.size && chunks < 256 {
            let h = file.read(at: offset, count: 8)
            guard h.count == 8 else { break }
            let id = h.latin1(0, 4)
            let size = h.u32be(4)
            if id == "COMM" {
                let c = file.read(at: offset + 8, count: 18)
                let frames = c.u32be(2)
                let rate = extended80(c.bytes(8, 10))
                if rate > 0 {
                    info.sampleRate = Int(rate)
                    info.duration = Double(frames) / rate
                }
            } else if id.lowercased() == "id3 " {
                let tag = file.read(at: offset + 8, count: size)
                ID3v2.parse(tag, into: &info, wantArtwork: wantArtwork)
            }
            offset += 8 + Int64(size) + Int64(size & 1)
            chunks += 1
        }
        return info
    }

    /// IEEE 754 80-bit extended (AIFF sample rate).
    private static func extended80(_ b: [UInt8]) -> Double {
        guard b.count == 10 else { return 0 }
        let exponent = Int(b[0] & 0x7F) << 8 | Int(b[1])
        let mantissa = b.u64be(2)
        if exponent == 0 && mantissa == 0 { return 0 }
        return Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
    }
}
