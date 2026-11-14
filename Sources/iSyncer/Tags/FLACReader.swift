import Foundation

enum FLACReader {
    static func read(_ file: FileReader, wantArtwork: Bool) -> TagInfo? {
        var info = TagInfo()
        info.codec = "FLAC"
        info.lossless = true

        // Some taggers put an ID3v2 tag in front of FLAC; skip it.
        var offset = Int64(ID3v2.tagLength(file.read(at: 0, count: 10)))
        guard file.read(at: offset, count: 4).matches("fLaC", at: 0) else { return nil }
        offset += 4

        var isLast = false
        var blocks = 0
        while !isLast && blocks < 128 {
            let header = file.read(at: offset, count: 4)
            guard header.count == 4 else { break }
            isLast = header[0] & 0x80 != 0
            let type = Int(header[0] & 0x7F)
            let length = header.u24be(1)
            let dataOffset = offset + 4
            offset = dataOffset + Int64(length)
            blocks += 1

            switch type {
            case 0: // STREAMINFO
                let b = file.read(at: dataOffset, count: 34)
                guard b.count == 34 else { continue }
                let v = b.u64be(10)
                let sampleRate = Int(v >> 44)
                let totalSamples = Double(v & 0xF_FFFF_FFFF)
                info.sampleRate = sampleRate
                if sampleRate > 0 { info.duration = totalSamples / Double(sampleRate) }
            case 4: // VORBIS_COMMENT
                let b = file.read(at: dataOffset, count: length)
                TagReader.parseVorbisComments(b, at: 0, into: &info, wantArtwork: wantArtwork)
            case 6: // PICTURE
                if wantArtwork {
                    let b = file.read(at: dataOffset, count: length)
                    let type = b.u32be(0)
                    if info.artwork == nil || type == 3, let data = parsePicture(b) {
                        info.artwork = data
                    }
                }
            default:
                break
            }
        }
        return info
    }

    /// FLAC PICTURE block (also used base64-encoded in Ogg METADATA_BLOCK_PICTURE).
    static func parsePicture(_ b: [UInt8]) -> Data? {
        var o = 4
        let mimeLen = b.u32be(o); o += 4 + mimeLen
        let descLen = b.u32be(o); o += 4 + descLen
        o += 16 // width, height, depth, colours
        let len = b.u32be(o); o += 4
        guard len > 0, o + len <= b.count else { return nil }
        return Data(b[o..<(o + len)])
    }
}

enum OggReader {
    static func read(_ file: FileReader, wantArtwork: Bool) -> TagInfo? {
        // Collect the first two logical packets (identification + comments).
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var offset: Int64 = 0
        var pages = 0
        let limit = 32 * 1024 * 1024

        while packets.count < 2 && pages < 4096 {
            let header = file.read(at: offset, count: 27)
            guard header.count == 27, header.matches("OggS", at: 0) else { break }
            let segments = Int(header[26])
            let table = file.read(at: offset + 27, count: segments)
            guard table.count == segments else { break }
            let bodyLen = table.reduce(0) { $0 + Int($1) }
            let body = file.read(at: offset + 27 + Int64(segments), count: bodyLen)
            offset += 27 + Int64(segments) + Int64(bodyLen)
            pages += 1

            var pos = 0
            for seg in table {
                let n = Int(seg)
                if pos + n <= body.count { current.append(contentsOf: body[pos..<(pos + n)]) }
                pos += n
                if n < 255 {      // packet ends here
                    packets.append(current)
                    current = []
                    if packets.count == 2 { break }
                }
            }
            if current.count > limit { break }
        }
        guard let ident = packets.first else { return nil }

        var info = TagInfo()
        var preSkip = 0
        var rate = 0
        if ident.matches("OpusHead", at: 0) {
            info.codec = "Opus"
            preSkip = ident.u16le(10)
            rate = 48000
            info.sampleRate = ident.u32le(12)
            if packets.count > 1, packets[1].matches("OpusTags", at: 0) {
                TagReader.parseVorbisComments(packets[1], at: 8, into: &info, wantArtwork: wantArtwork)
            }
        } else if ident.count > 7, ident[0] == 1, ident.matches("vorbis", at: 1) {
            info.codec = "Vorbis"
            rate = ident.u32le(12)
            info.sampleRate = rate
            let nominal = ident.u32le(20)
            if nominal > 0 && nominal < 2_000_000 { info.bitrate = nominal / 1000 }
            if packets.count > 1, packets[1].count > 7, packets[1][0] == 3, packets[1].matches("vorbis", at: 1) {
                TagReader.parseVorbisComments(packets[1], at: 7, into: &info, wantArtwork: wantArtwork)
            }
        } else if ident.count > 5, ident[0] == 0x7F, ident.matches("FLAC", at: 1) {
            info.codec = "FLAC"
            info.lossless = true
            // Ogg FLAC: STREAMINFO follows the 13-byte mapping header + "fLaC" + 4-byte block header.
            let si = 13 + 4 + 4
            let v = ident.u64be(si + 10)
            rate = Int(v >> 44)
            info.sampleRate = rate
            if packets.count > 1 {
                TagReader.parseVorbisComments(packets[1], at: 4, into: &info, wantArtwork: wantArtwork)
            }
        } else {
            return nil
        }

        // Duration from the last page's granule position.
        let tailLen = Int(min(file.size, 128 * 1024))
        let tail = file.read(at: file.size - Int64(tailLen), count: tailLen)
        if rate > 0, let last = tail.findLast("OggS") {
            let granule = tail.u64le(last + 6)
            if granule != UInt64.max, granule > UInt64(preSkip) {
                info.duration = Double(granule - UInt64(preSkip)) / Double(rate)
            }
        }
        return info
    }
}
