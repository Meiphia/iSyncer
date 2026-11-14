import Foundation

enum ID3v2 {
    /// Total tag length (header + body + footer) if an ID3v2 tag starts at offset 0 of `head`.
    static func tagLength(_ head: [UInt8]) -> Int {
        guard head.count >= 10, head.matches("ID3", at: 0) else { return 0 }
        let footer = (head[5] & 0x10) != 0 ? 10 : 0
        return 10 + head.syncsafe(6) + footer
    }

    /// Parses a complete ID3v2 tag (starting with "ID3") into `info`.
    static func parse(_ tag: [UInt8], into info: inout TagInfo, wantArtwork: Bool) {
        guard tag.count >= 10, tag.matches("ID3", at: 0) else { return }
        let major = tag.u8(3)
        let flags = tag[5]
        let size = tag.syncsafe(6)
        var body = tag.bytes(10, size)
        if flags & 0x80 != 0 && major < 4 { body = deUnsync(body) }

        var o = 0
        if flags & 0x40 != 0 {   // extended header
            if major == 3 { o = 4 + body.u32be(0) } else if major == 4 { o = body.syncsafe(0) }
        }

        let idLen = major == 2 ? 3 : 4
        let headerLen = major == 2 ? 6 : 10
        var tlenMs = 0

        while o + headerLen <= body.count {
            let id = body.latin1(o, idLen)
            if id.first == "\0" || id.isEmpty { break }
            let frameSize: Int
            switch major {
            case 2: frameSize = body.u24be(o + 3)
            case 4: frameSize = body.syncsafe(o + 4)
            default: frameSize = body.u32be(o + 4)
            }
            let frameFlags = major >= 3 ? body.u16be(o + 8) : 0
            let start = o + headerLen
            guard frameSize > 0, start + frameSize <= body.count else { break }
            var data = body.bytes(start, frameSize)
            o = start + frameSize

            if major == 4 {
                if frameFlags & 0x0002 != 0 { data = deUnsync(data) }        // per-frame unsync
                if frameFlags & 0x0001 != 0, data.count >= 4 { data = Array(data.dropFirst(4)) } // data length indicator
                if frameFlags & 0x0008 != 0 || frameFlags & 0x0004 != 0 { continue } // compressed/encrypted
            } else if major == 3, frameFlags & 0x00C0 != 0 {
                continue // compressed/encrypted v2.3 frames
            }

            switch id {
            case "TIT2", "TT2": set(&info.title, text(data))
            case "TPE1", "TP1": set(&info.artist, text(data))
            case "TPE2", "TP2": set(&info.albumArtist, text(data))
            case "TALB", "TAL": set(&info.album, text(data))
            case "TCON", "TCO": set(&info.genre, genre(text(data)))
            case "TYER", "TYE", "TDRC", "TDOR", "TORY":
                if info.year == 0 { info.year = TagReader.parseYear(text(data)) }
            case "TRCK", "TRK":
                info.track = TagReader.parseNumber(text(data))
                info.trackTotal = TagReader.parseTotal(text(data))
            case "TPOS", "TPA":
                info.disc = TagReader.parseNumber(text(data))
                info.discTotal = TagReader.parseTotal(text(data))
            case "TCOM", "TCM": set(&info.composer, text(data))
            case "TIT1", "TT1", "GRP1": set(&info.grouping, text(data))
            case "TBPM", "TBP": info.bpm = TagReader.parseNumber(text(data))
            case "TCMP", "TCP": info.compilation = text(data) == "1"
            case "USLT", "ULT":
                if info.lyrics == nil, data.count > 4, data.count <= Lyrics.maximumSize,
                   let value = lyricString(data, start: 4, encoding: Int(data[0])) {
                    info.lyrics = lyricString(data, start: value.next, encoding: Int(data[0]), terminated: false)?.text
                }
            case "SYLT", "SLT":
                // Timestamp format 2 stores milliseconds. MPEG-frame timestamps need stream timing.
                if info.timedLyrics.isEmpty, data.count > 6, data.count <= Lyrics.maximumSize, data[4] == 2,
                   let descriptor = lyricString(data, start: 6, encoding: Int(data[0])) {
                    var offset = descriptor.next
                    while let line = lyricString(data, start: offset, encoding: Int(data[0])), line.next + 4 <= data.count {
                        info.timedLyrics.append(.init(time: Double(data.u32be(line.next)) / 1000, text: line.text))
                        offset = line.next + 4
                    }
                }
            case "COMM", "COM":
                // encoding, 3-byte language, description, text
                if info.comment.isEmpty, data.count > 4 {
                    let parts = decode(Array(data.dropFirst(4)), encoding: Int(data[0]))
                    // Skip iTunes' hidden iTunNORM/iTunSMPB comment frames.
                    let hidden = parts.count > 1 && (parts.first?.hasPrefix("iTun") ?? false)
                    if !hidden, let last = parts.last { info.comment = last }
                }
            case "TXXX", "TXX":
                // encoding, description, value
                if data.count > 1 {
                    let parts = decode(Array(data.dropFirst()), encoding: Int(data[0]))
                    if parts.count >= 2, parts[0].uppercased().hasPrefix("REPLAYGAIN_") {
                        TagReader.applyReplayGain(parts[0], parts[1], to: &info)
                    }
                }
            case "TLEN", "TLE": tlenMs = Int(text(data).trimmingCharacters(in: .whitespaces)) ?? 0
            case "APIC":
                if wantArtwork { takePicture(&info, apic(data)) }
            case "PIC":
                if wantArtwork { takePicture(&info, pic(data)) }
            default: break
            }
        }
        if info.duration == 0, tlenMs > 0 { info.duration = Double(tlenMs) / 1000 }
    }

    private static func lyricString(_ data: [UInt8], start: Int, encoding: Int,
                                    terminated: Bool = true) -> (text: String, next: Int)? {
        let width = encoding == 1 || encoding == 2 ? 2 : 1
        guard start <= data.count else { return nil }
        var end = start
        if terminated {
            while end + width <= data.count && data[end..<(end + width)].contains(where: { $0 != 0 }) {
                end += width
            }
            guard end + width <= data.count else { return nil }
        } else {
            end = data.count
        }
        let text = decode(Array(data[start..<end]), encoding: encoding).joined(separator: "\n")
        return (text, end + (terminated ? width : 0))
    }

    private static func set(_ field: inout String, _ value: String) {
        if field.isEmpty, !value.isEmpty { field = value }
    }

    private static func takePicture(_ info: inout TagInfo, _ pic: (type: Int, data: [UInt8])?) {
        guard let pic, !pic.data.isEmpty else { return }
        // Prefer the front cover (type 3); otherwise take the first picture found.
        if info.artwork == nil || pic.type == 3 { info.artwork = Data(pic.data) }
    }

    static func deUnsync(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0x00 { i += 2 } else { i += 1 }
        }
        return out
    }

    /// Text frame: encoding byte + string(s). Returns the first value.
    static func text(_ d: [UInt8]) -> String {
        guard let enc = d.first else { return "" }
        return decode(Array(d.dropFirst()), encoding: Int(enc)).first ?? ""
    }

    /// Splits on the encoding's terminator and decodes each piece.
    static func decode(_ b: [UInt8], encoding: Int) -> [String] {
        var parts: [String] = []
        if encoding == 1 || encoding == 2 {
            var cur: [UInt8] = []
            var i = 0
            while i + 1 < b.count {
                if b[i] == 0 && b[i + 1] == 0 {
                    parts.append(utf16(cur, bigEndianDefault: encoding == 2)); cur = []
                } else {
                    cur.append(b[i]); cur.append(b[i + 1])
                }
                i += 2
            }
            if !cur.isEmpty { parts.append(utf16(cur, bigEndianDefault: encoding == 2)) }
        } else {
            for piece in b.split(separator: 0, omittingEmptySubsequences: false) {
                let arr = Array(piece)
                parts.append(encoding == 3 ? String(decoding: arr, as: UTF8.self) : arr.latin1(0, arr.count))
            }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func utf16(_ b: [UInt8], bigEndianDefault: Bool) -> String {
        var bytes = b
        var bigEndian = bigEndianDefault
        if bytes.count >= 2 {
            if bytes[0] == 0xFF && bytes[1] == 0xFE { bigEndian = false; bytes.removeFirst(2) }
            else if bytes[0] == 0xFE && bytes[1] == 0xFF { bigEndian = true; bytes.removeFirst(2) }
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                                   : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// "(17)", "17", "(17)Rock" or plain text → genre name.
    static func genre(_ s: String) -> String {
        var t = s
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") {
            let num = t[t.index(after: t.startIndex)..<close]
            let rest = String(t[t.index(after: close)...])
            if !rest.isEmpty { return rest }
            t = String(num)
        }
        if let n = Int(t) { return TagReader.genreName(index: n) }
        return t
    }

    private static func apic(_ d: [UInt8]) -> (type: Int, data: [UInt8])? {
        guard d.count > 4 else { return nil }
        let enc = Int(d[0])
        var o = 1
        while o < d.count && d[o] != 0 { o += 1 }   // MIME type
        o += 1
        guard o < d.count else { return nil }
        let type = Int(d[o]); o += 1
        o = skipDescription(d, from: o, encoding: enc)
        guard o < d.count else { return nil }
        return (type, Array(d[o...]))
    }

    private static func pic(_ d: [UInt8]) -> (type: Int, data: [UInt8])? {
        guard d.count > 6 else { return nil }
        let enc = Int(d[0])
        let type = Int(d[4])
        let o = skipDescription(d, from: 5, encoding: enc)
        guard o < d.count else { return nil }
        return (type, Array(d[o...]))
    }

    private static func skipDescription(_ d: [UInt8], from start: Int, encoding: Int) -> Int {
        var o = start
        if encoding == 1 || encoding == 2 {
            while o + 1 < d.count && !(d[o] == 0 && d[o + 1] == 0) { o += 2 }
            return o + 2
        }
        while o < d.count && d[o] != 0 { o += 1 }
        return o + 1
    }
}

enum MP3Reader {
    private static let bitratesV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
    private static let bitratesV2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
    private static let bitratesV1L2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]

    static func read(_ file: FileReader, wantArtwork: Bool) -> TagInfo? {
        var info = TagInfo()
        info.codec = "MP3"

        let head = file.read(at: 0, count: 10)
        let tagLen = ID3v2.tagLength(head)
        if tagLen > 0 {
            let tag = file.read(at: 0, count: tagLen)
            ID3v2.parse(tag, into: &info, wantArtwork: wantArtwork)
        }

        // ID3v1 fallback at the end of the file.
        var audioEnd = file.size
        let tail = file.read(at: file.size - 128, count: 128)
        if tail.count == 128, tail.matches("TAG", at: 0) {
            audioEnd -= 128
            if info.title.isEmpty { info.title = v1(tail, 3, 30) }
            if info.artist.isEmpty { info.artist = v1(tail, 33, 30) }
            if info.album.isEmpty { info.album = v1(tail, 63, 30) }
            if info.year == 0 { info.year = Int(v1(tail, 93, 4)) ?? 0 }
            if info.track == 0, tail[125] == 0, tail[126] != 0 { info.track = Int(tail[126]) }
            if info.genre.isEmpty { info.genre = TagReader.genreName(index: Int(tail[127])) }
        }

        // Find the first MPEG frame after the tag.
        let scanStart = Int64(tagLen)
        let buf = file.read(at: scanStart, count: 128 * 1024)
        guard let (offset, frame) = firstFrame(buf) else {
            return info.title.isEmpty && info.artist.isEmpty ? nil : info
        }
        info.sampleRate = frame.sampleRate
        let audioStart = scanStart + Int64(offset)

        // Xing/Info (VBR) header, then VBRI, else assume CBR.
        let side = frame.mpeg1 ? (frame.mono ? 17 : 32) : (frame.mono ? 9 : 17)
        let x = offset + 4 + side
        if buf.matches("Xing", at: x) || buf.matches("Info", at: x) {
            let flags = buf.u32be(x + 4)
            if flags & 0x1 != 0 {
                let frames = buf.u32be(x + 8)
                info.duration = Double(frames * frame.samplesPerFrame) / Double(frame.sampleRate)
            }
        } else if buf.matches("VBRI", at: offset + 36) {
            let frames = buf.u32be(offset + 36 + 14)
            info.duration = Double(frames * frame.samplesPerFrame) / Double(frame.sampleRate)
        }
        if info.duration == 0, frame.bitrate > 0 {
            info.duration = Double(audioEnd - audioStart) * 8 / Double(frame.bitrate * 1000)
            info.bitrate = frame.bitrate
        }
        return info
    }

    private static func v1(_ b: [UInt8], _ o: Int, _ n: Int) -> String {
        let raw = b.bytes(o, n).prefix(while: { $0 != 0 })
        return Array(raw).latin1(0, raw.count).trimmingCharacters(in: .whitespaces)
    }

    struct Frame {
        let mpeg1: Bool
        let mono: Bool
        let bitrate: Int
        let sampleRate: Int
        let samplesPerFrame: Int
        let length: Int
    }

    private static func parseHeader(_ b: [UInt8], _ i: Int) -> Frame? {
        guard i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let version = Int((b[i + 1] >> 3) & 0x3)    // 0 = 2.5, 2 = 2, 3 = 1
        let layer = Int((b[i + 1] >> 1) & 0x3)      // 1 = III, 2 = II, 3 = I
        let brIndex = Int(b[i + 2] >> 4)
        let srIndex = Int((b[i + 2] >> 2) & 0x3)
        let padding = Int((b[i + 2] >> 1) & 0x1)
        let mono = (b[i + 3] >> 6) == 3
        guard version != 1, layer != 0, brIndex != 0, brIndex != 15, srIndex != 3 else { return nil }

        let mpeg1 = version == 3
        let rates = [[11025, 12000, 8000], [0, 0, 0], [22050, 24000, 16000], [44100, 48000, 32000]]
        let sampleRate = rates[version][srIndex]
        let bitrate: Int
        if layer == 1 { bitrate = mpeg1 ? bitratesV1L3[brIndex] : bitratesV2L3[brIndex] }
        else if layer == 2 { bitrate = mpeg1 ? bitratesV1L2[brIndex] : bitratesV2L3[brIndex] }
        else { bitrate = mpeg1 ? bitratesV1L2[brIndex] : bitratesV2L3[brIndex] }
        let spf = layer == 3 ? 384 : (layer == 2 || mpeg1 ? 1152 : 576)
        let length = layer == 3
            ? (12 * bitrate * 1000 / sampleRate + padding) * 4
            : spf / 8 * bitrate * 1000 / sampleRate + padding
        return Frame(mpeg1: mpeg1, mono: mono, bitrate: bitrate, sampleRate: sampleRate,
                     samplesPerFrame: spf, length: length)
    }

    /// First frame whose successor also parses — avoids false syncs inside junk data.
    private static func firstFrame(_ b: [UInt8]) -> (Int, Frame)? {
        var i = 0
        while i + 4 <= b.count {
            if b[i] == 0xFF, let f = parseHeader(b, i) {
                let next = i + f.length
                if next + 4 > b.count || parseHeader(b, next) != nil { return (i, f) }
            }
            i += 1
        }
        return nil
    }
}
