import Foundation

public struct DevicePlayCount: Equatable, Sendable {
    public let id: Data
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String
    public let duration: Int
    let durationMilliseconds: Int
    public let total: Int
    public let recent: Int
    public let lastPlayed: Int
    public let latestEvent: Int
    public let kind: ClassicMediaKind
    public let rating: Int
    public let bookmarkMilliseconds: Int
    public let played: Bool
    let markedPlayed: Bool
    let remembersPosition: Bool
    public let enclosure: String
    public let videoSyncKey: String?
    public let filePath: String
    public let fileSize: Int
}

public struct ClassicListeningState: Codable, Equatable, Sendable {
    public let milliseconds: Int
    public let played: Bool

    public init(seconds: Double, played: Bool) {
        self.init(milliseconds: seconds.isFinite ? Int(max(0, min(Double(UInt32.max), (seconds * 1000).rounded()))) : 0,
                  played: played)
    }

    init(milliseconds: Int, played: Bool) {
        self.milliseconds = milliseconds
        self.played = played
    }
}

public extension DevicePlayCount {
    var listeningState: ClassicListeningState {
        ClassicListeningState(milliseconds: bookmarkMilliseconds,
                              played: kind == .podcast || kind == .audiobook ? played && bookmarkMilliseconds == 0 : played)
    }
}

public extension ClassicListeningState {
    func matches(_ other: Self) -> Bool {
        played == other.played && abs(milliseconds - other.milliseconds) < 500
    }

    // An empty bookmark at first connection is treated as no progress.
    static func reconcile(mac: Self, iPod: Self, last: Self?) -> ListeningDecision {
        if mac.matches(iPod) { return .same }
        let baseline = last ?? Self(seconds: 0, played: false)
        if mac.matches(baseline) { return .useIPod }
        if iPod.matches(baseline) { return .useMac }
        return .conflict
    }

    enum ListeningDecision: Equatable {
        case same, useMac, useIPod, conflict
    }
}

extension Database {
    private func playCountLayout(_ counts: Data) throws -> (offset: Int, stride: Int, count: Int) {
        guard counts.count >= 96, counts.isTag("mhdp", at: 0) else {
            throw SyncError("The iPod Play Counts file has an unsupported header.")
        }
        let offset = counts.u32(4)
        let stride = counts.u32(8)
        let count = counts.u32(12)
        guard offset >= 96, offset <= counts.count, stride >= 12,
              count <= tracks.count, count <= (counts.count - offset) / stride else {
            throw SyncError("The iPod Play Counts file does not match the current track list.")
        }
        return (offset, stride, count)
    }

    func playCounts(_ counts: Data, removing trackIDs: Set<Int>,
                    listening: [String: ClassicListeningState] = [:]) throws -> Data {
        let (offset, stride, count) = try playCountLayout(counts)
        var result = Data(counts.prefix(offset))
        var remaining = 0
        for index in 0..<count where !trackIDs.contains(tracks[index].id) {
            let start = offset + index * stride
            var row = counts.subdata(in: start..<start + stride)
            if let state = listening[tracks[index].path.lowercased()] {
                row.put(state.milliseconds, at: 8)
            }
            result.append(row)
            remaining += 1
        }
        result.append(counts.dropFirst(offset + count * stride))
        result.put(remaining, at: 12)
        return result
    }

    func devicePlays(_ counts: Data?, plist: Data? = nil, includeVideo: Bool = false) throws -> [DevicePlayCount] {
        let (offset, stride, count) = try counts.map(playCountLayout) ?? (0, 0, 0)
        var events: [Data: (count: Int, time: Int, bookmark: Int?, rating: Int?)] = [:]
        if let plist {
            let object = try PropertyListSerialization.propertyList(from: plist, format: nil)
            guard let rows = (object as? [String: Any])?["tracks"] as? [[String: Any]] else {
                throw SyncError("The iPod PlayCounts.plist file has an unsupported format.")
            }
            for row in rows {
                guard let id = row["persistentID"] as? NSNumber else { continue }
                let count = (row["playCount"] as? NSNumber)?.intValue ?? 0
                guard (0...Int(UInt32.max)).contains(count) else { continue }
                var value = id.uint64Value.littleEndian
                let key = withUnsafeBytes(of: &value) { Data($0) }
                let time = (row["playMacOSDate"] as? NSNumber)?.intValue ?? 0
                events[key] = (count, (0...Int(UInt32.max)).contains(time) ? time : 0,
                               (row["bookmarkTimeInMS"] as? NSNumber)?.intValue,
                               (row["userRating"] as? NSNumber)?.intValue)
            }
        }
        guard let section = sectionsForPlays else { return [] }
        return zip(tracks, section).enumerated().compactMap { index, pair in
            let (track, record) = pair
            let kind = ClassicMediaKind(rawValue: track.mediaType == 0 ? 1 : track.mediaType)
            guard let kind, [.music, .podcast, .audiobook].contains(kind) ||
                (includeVideo && [.tvShow, .movie].contains(kind)) else { return nil }
            let start = record.offset
            let row = offset + index * stride
            let recent = events[track.persistentID]?.count ?? (index < count ? counts?.u32(row) ?? 0 : 0)
            let last = events[track.persistentID]?.time ?? (index < count && recent > 0 ? counts?.u32(row + 4) ?? 0 : 0)
            let bookmark = events[track.persistentID]?.bookmark ?? (index < count ? counts?.u32(row + 8) ?? 0 : 0)
            let rating = events[track.persistentID]?.rating ?? (index < count && stride >= 16 ? counts?.u32(row + 12) ?? -1 : -1)
            let duration = original.u32(start + 0x28)
            let markedPlayed = record.header > 0xb2 && original[start + 0xb2] == 1
            return DevicePlayCount(id: track.persistentID, title: track.fields[1] ?? "",
                                   artist: track.fields[4] ?? "", album: track.fields[3] ?? "",
                                   albumArtist: track.fields[22] ?? "", duration: duration / 1000, durationMilliseconds: duration,
                                   total: original.u32(start + 0x50) + recent, recent: recent,
                                   lastPlayed: max(0, max(last, original.u32(start + 0x58)) - 2_082_844_800),
                                   latestEvent: max(0, last - 2_082_844_800), kind: kind,
                                   rating: ((1...100).contains(rating) ? rating : min(100, Int(original[start + 0x1f]))) / 20,
                                   bookmarkMilliseconds: (1...max(1, duration)).contains(bookmark) ? bookmark : original.u32(start + 0x6c),
                                   played: recent > 0 || (includeVideo && kind == .tvShow && original.u32(start + 0x50) > 0) || markedPlayed,
                                   markedPlayed: markedPlayed, remembersPosition: record.header > 0xa6 && original[start + 0xa6] == 1,
                                   enclosure: track.fields[15] ?? "", videoSyncKey: kind == .tvShow || kind == .movie ? track.videoSyncKey : nil,
                                   filePath: track.path.lowercased(), fileSize: track.size)
        }
    }
}
