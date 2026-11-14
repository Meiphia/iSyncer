import Foundation

struct Lyrics: Sendable {
    struct Line: Sendable {
        let time: Double
        let text: String
    }

    static let maximumSize = 512 * 1024
    let plain: String
    let timed: [Line]

    static func load(from url: URL) -> Lyrics {
        let base = url.deletingPathExtension()
        let lrc = readText(base.appendingPathExtension("lrc")).map(parse)
        let txt = readText(base.appendingPathExtension("txt"))
        let tags = TagReader.read(url: url)
        let embedded = tags?.lyrics.map(parse)
        let embeddedTimed = tags?.timedLyrics ?? []
        let timed = [lrc?.timed ?? [], embeddedTimed, embedded?.timed ?? []].first { !$0.isEmpty } ?? []
        let plain = [txt, embedded?.plain, lrc?.plain, timed.map(\.text).joined(separator: "\n")]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return Lyrics(plain: plain, timed: timed.sorted { $0.time < $1.time })
    }

    static func parse(_ input: String) -> Lyrics {
        let value = input.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var timed: [Line] = []
        var offset = 0.0
        for line in value.components(separatedBy: .newlines) {
            if let tag = line.wholeMatch(of: #/\[offset:([+-]?\d+)\]/#), let milliseconds = Double(tag.1) {
                offset = milliseconds / 1000
                continue
            }
            var remaining = line[...]
            var timestamps: [Double] = []
            while let tag = remaining.prefixMatch(of: #/\[(\d{1,4}):(\d{2})(?:[.:](\d{1,3}))?\]/#),
                  let minutes = Double(tag.1), let seconds = Double(tag.2), seconds < 60 {
                let fraction = tag.3.flatMap { Double("0." + $0) } ?? 0
                timestamps.append(minutes * 60 + seconds + fraction)
                remaining = remaining[tag.range.upperBound...]
            }
            let text = remaining.replacingOccurrences(of: #"<\d{1,4}:\d{2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            timed.append(contentsOf: timestamps.map { .init(time: $0, text: text) })
        }
        guard !timed.isEmpty else { return Lyrics(plain: value, timed: []) }
        timed = timed.map { .init(time: max(0, $0.time + offset), text: $0.text) }.sorted { $0.time < $1.time }
        return Lyrics(plain: timed.map(\.text).joined(separator: "\n"), timed: timed)
    }

    private static func readText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...maximumSize).contains(size),
              let data = try? Data(contentsOf: url), data.count <= maximumSize else { return nil }
        let bom = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        if bom { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    }
}
