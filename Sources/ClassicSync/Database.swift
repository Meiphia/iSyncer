import Foundation

public struct SyncError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension Data {
    func u16(_ offset: Int) -> Int {
        Int(self[offset]) | (Int(self[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> Int {
        u16(offset) | (u16(offset + 2) << 16)
    }

    mutating func put(_ value: Int, at offset: Int) {
        for byte in 0..<4 { self[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
    }

    mutating func putID(_ id: UInt64, at offset: Int) {
        put(Int(UInt32(truncatingIfNeeded: id)), at: offset)
        put(Int(id >> 32), at: offset + 4)
    }

    func isTag(_ tag: String, at offset: Int) -> Bool {
        offset >= 0 && offset <= count - 4 && self[offset..<(offset + 4)].elementsEqual(tag.utf8)
    }

    static func record(_ tag: String, header: Int, children: [Data] = []) -> Data {
        var data = Data(count: header)
        data.replaceSubrange(0..<4, with: tag.utf8)
        data.put(header, at: 4)
        for child in children { data.append(child) }
        data.put(data.count, at: 8)
        return data
    }
}

struct Chunk {
    let offset: Int
    let header: Int
    let length: Int
    var end: Int { offset + length }
    var body: Int { offset + header }

    init(_ data: Data, at offset: Int, before end: Int, tag: String, minimum: Int, isList: Bool = false) throws {
        guard end <= data.count, offset >= 0, offset <= end - minimum, data.isTag(tag, at: offset) else {
            throw SyncError("The iPod database has an unexpected \(tag) record.")
        }
        let header = data.u32(offset + 4)
        let length = isList ? header : data.u32(offset + 8)
        guard header >= minimum, length >= header, length <= end - offset else {
            throw SyncError("The iPod database has a damaged \(tag) record.")
        }
        self.offset = offset
        self.header = header
        self.length = length
    }

    func bytes(in data: Data) -> Data { data.subdata(in: offset..<end) }
    func headerBytes(in data: Data) -> Data { data.subdata(in: offset..<body) }
}

struct Database {
    private static let releaseDateOffset = 0x8c

    static func releaseTimestamp(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let seconds = (date.timeIntervalSince1970 + 2_082_844_800).rounded(.down)
        guard seconds >= 1, seconds <= Double(UInt32.max) else { return nil }
        return Int(seconds)
    }

    struct Track {
        let id: Int
        let persistentID: Data
        var fields: [Int: String]
        let size: Int
        let disc: Int
        let number: Int
        let artworkID: Int
        let mediaType: Int
        let season: Int
        let episode: Int
        let releaseTimestamp: Int
        var path: String { fields[2] ?? "" }
        var videoSyncKey: String {
            Song.videoSyncKey(tv: mediaType & 64 != 0, show: fields[19] ?? fields[3] ?? "",
                              season: season, episode: episode, title: fields[1] ?? "")
        }
    }

    struct Addition {
        let song: Song
        let path: String
        var replacesTrackID: Int? = nil
    }

    private struct Section {
        let kind: Int
        let chunk: Chunk
        let list: Chunk?
        let records: [Chunk]
    }

    let original: Data
    let tracks: [Track]
    private let root: Chunk
    private let sections: [Section]
    var sectionsForPlays: [Chunk]? { sections.first { $0.kind == 1 }?.records }

    init(_ data: Data) throws {
        root = try Chunk(data, at: 0, before: data.count, tag: "mhbd", minimum: 0xa0)
        guard root.end == data.count else { throw SyncError("Unexpected data after the iPod database.") }
        original = data
        var offset = root.body
        var sections: [Section] = []
        var tracks: [Track] = []
        for _ in 0..<data.u32(20) {
            let chunk = try Chunk(data, at: offset, before: root.end, tag: "mhsd", minimum: 16)
            let kind = data.u32(offset + 12)
            var list: Chunk?
            var records: [Chunk] = []
            let listTypes = [1: ("mhlt", "mhit", 0x7c), 2: ("mhlp", "mhyp", 24),
                             3: ("mhlp", "mhyp", 24), 4: ("mhla", "mhia", 28)]
            if let (listTag, recordTag, minimum) = listTypes[kind] {
                let parsedList = try Chunk(data, at: chunk.body, before: chunk.end, tag: listTag, minimum: 12, isList: true)
                list = parsedList
                var position = parsedList.body
                for _ in 0..<data.u32(parsedList.offset + 8) {
                    let record = try Chunk(data, at: position, before: chunk.end, tag: recordTag, minimum: minimum)
                    records.append(record)
                    if kind == 1 {
                        let fields = try Self.fields(data, record: record)
                        tracks.append(Track(id: data.u32(position + 16),
                                            persistentID: data.subdata(in: position + 0x70..<position + 0x78),
                                            fields: fields, size: data.u32(position + 0x24),
                                            disc: data.u32(position + 0x5c), number: data.u32(position + 0x2c),
                                            artworkID: record.header >= 0x164 ? data.u32(position + 0x160) : 0,
                                            mediaType: record.header >= 0xd4 ? data.u32(position + 0xd0) : 1,
                                            season: record.header >= 0xdc ? data.u32(position + 0xd4) : 0,
                                            episode: record.header >= 0xdc ? data.u32(position + 0xd8) : 0,
                                            releaseTimestamp: record.header >= Self.releaseDateOffset + 4
                                                ? data.u32(position + Self.releaseDateOffset) : 0))
                    }
                    position = record.end
                }
                guard position == chunk.end else { throw SyncError("Unexpected data at the end of the \(listTag) list.") }
            }
            sections.append(Section(kind: kind, chunk: chunk, list: list, records: records))
            offset = chunk.end
        }
        guard offset == root.end, sections.filter({ $0.kind == 1 }).count == 1,
              sections.contains(where: { $0.kind == 2 }) else {
            throw SyncError("The iPod database is missing its track or playlist section.")
        }
        guard Set(tracks.map(\.id)).count == tracks.count else {
            throw SyncError("The iPod database contains duplicate track IDs.")
        }
        self.sections = sections
        self.tracks = tracks
    }

    func playlistUpdates() throws -> [Data: PlaylistUpdate] {
        guard let section = sections.first(where: { $0.kind == 2 }) else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.path.lowercased()) })
        var result: [Data: PlaylistUpdate] = [:]
        for record in section.records where record.header >= 36 && original[record.offset + 20] & 1 == 0 {
            let id = original.subdata(in: record.offset + 28..<record.offset + 36)
            let name = try Self.fields(original, record: record)[1] ?? ""
            var offset = record.body
            for _ in 0..<original.u32(record.offset + 12) {
                offset = try Chunk(original, at: offset, before: record.end, tag: "mhod", minimum: 24).end
            }
            var paths: [String] = []
            for _ in 0..<original.u32(record.offset + 16) {
                let item = try Chunk(original, at: offset, before: record.end, tag: "mhip", minimum: 28)
                if let path = byID[original.u32(offset + 24)] { paths.append(path) }
                offset = item.end
            }
            result[id] = PlaylistUpdate(id: id, name: name, paths: paths)
        }
        return result
    }

    struct PlaylistUpdate: Equatable {
        let id: Data
        let name: String
        let paths: [String]
    }

    func defaultPlaylistNames(excluding protectedIDs: Set<Data>) throws -> [Data: String] {
        let names: Set<String> = ["genius", "90s music", "classical music", "music videos", "my top rated",
                                  "recently added", "recently played", "top 25 most played", "my top 25 most played"]
        var matches: [Data: String] = [:]
        for section in sections where section.kind == 2 || section.kind == 3 {
            for record in section.records where record.header >= 44 &&
                original[record.offset + 20] & 1 == 0 && original.u16(record.offset + 42) != 1 {
                let id = original.subdata(in: record.offset + 28..<record.offset + 36)
                guard !protectedIDs.contains(id), let name = try Self.fields(original, record: record)[1] else { continue }
                let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
                if names.contains(key) { matches[id] = name }
            }
        }
        return matches
    }

    struct ArtworkLink {
        let id: Int
        let size: Int
    }

    func needsPodcastIndexRepair(for episodeIDs: Set<Int>) throws -> Bool {
        guard !episodeIDs.isEmpty else { return false }
        let podcasts = tracks.filter { episodeIDs.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: podcasts.map { ($0.id, $0) })
        guard sections.contains(where: { $0.kind == 3 }) else { return true }
        for section in sections where section.kind == 2 || section.kind == 3 {
            let grouped = section.kind == 3
            guard let record = section.records.first(where: { $0.header >= 44 && original.u16($0.offset + 42) == 1 }) else { return true }
            var offset = record.body
            for _ in 0..<original.u32(record.offset + 12) {
                offset = try Chunk(original, at: offset, before: record.end, tag: "mhod", minimum: 24).end
            }
            var seen = Set<Int>()
            var groups: [Int: String] = [:]
            var groupIDs: [String: Int] = [:]
            for _ in 0..<original.u32(record.offset + 16) {
                let item = try Chunk(original, at: offset, before: record.end, tag: "mhip", minimum: 36)
                let id = original.u32(offset + 24)
                if original.u32(offset + 16) == 256 {
                    let title = try Self.fields(original, record: item)[1] ?? ""
                    groups[original.u32(offset + 20)] = title
                } else if let episode = byID[id] {
                    guard seen.insert(id).inserted else { return true }
                    if grouped {
                        let groupID = original.u32(offset + 32)
                        let key = Self.podcastGroupKey(episode)
                        guard let title = groups[groupID],
                              title.utf8.elementsEqual(Self.podcastGroupTitle(episode).precomposedStringWithCanonicalMapping.utf8),
                              groupIDs[key] == nil || groupIDs[key] == groupID else { return true }
                        groupIDs[key] = groupID
                    }
                }
                offset = item.end
            }
            if seen != episodeIDs || offset != record.end { return true }
        }
        return false
    }

    func adding(_ additions: [Addition], playlists: [PlaylistUpdate] = [], removed: Set<Data> = [],
                removedTracks: Set<Int> = [],
                artistOverrides: [String: String] = [:], podcastUpdates: [String: Song] = [:],
                videoReleaseDates: [String: Int] = [:],
                videoTitles: [String: String] = [:],
                videoDescriptions: [String: String] = [:],
                episodeNumbers: [String: EpisodeCorrection] = [:],
                removedVideoArtwork: Set<String> = [],
                listening: [String: ClassicListeningState] = [:],
                rebuildPodcastIndex: Bool = false,
                artwork: (Track) throws -> ArtworkLink? = { _ in nil }) throws -> Data {
        let occupiedIDs = tracks.map(\.id) + sections.flatMap { section in
            section.records.map { record in original.u32(record.offset + 16) }
        }
        var nextID = max(1000, occupiedIDs.max() ?? 0) + 1
        guard nextID + additions.count * 3 < Int(UInt32.max) else {
            throw SyncError("There are no track IDs left in the iPod database.")
        }
        let albumSection = sections.first { $0.kind == 4 }
        var albumIDs: [[String]: Int] = [:]
        for record in albumSection?.records ?? [] {
            let fields = try Self.fields(original, record: record)
            albumIDs[Self.albumKey(fields[200] ?? "", fields[201] ?? "")] = original.u32(record.offset + 16)
        }
        var newAlbums: [Data] = []
        var newTracks: [Data] = []
        var newEntries: [Track] = []
        let libraryID = original.subdata(in: 0x24..<0x2c)
        let timestamp = Int(Date().timeIntervalSince1970) + 2_082_844_800
        let trackHeader = sections.first { $0.kind == 1 }?.records.first?.header ?? 624
        guard trackHeader >= 0x184 else {
            throw SyncError("This iTunesDB uses an older track layout.")
        }

        func resolveAlbum(_ title: String, _ artist: String) throws -> Int {
            let key = Self.albumKey(title, artist)
            if let id = albumIDs[key] { return id }
            guard !title.isEmpty, let albumSection else { return 0 }
            let id = nextID
            nextID += 1
            albumIDs[key] = id
            let children = [(200, title), (201, artist), (202, artist)].compactMap(Self.stringRecord)
            let header = albumSection.records.first?.header ?? 88
            guard header >= 40 else { throw SyncError("This iTunesDB uses an older album layout.") }
            var album = Data.record("mhia", header: header, children: children)
            album.put(children.count, at: 12)
            album.put(id, at: 16)
            album.putID(Self.randomID(), at: 20)
            album.put(2, at: 28)
            newAlbums.append(album)
            return id
        }

        var tracksByID = Dictionary(uniqueKeysWithValues: tracks.filter { !removedTracks.contains($0.id) }.map { ($0.id, $0) })
        let fileReplacements = Dictionary(uniqueKeysWithValues: additions.compactMap { entry in
            entry.replacesTrackID.map { ($0, entry) }
        })
        let updatesVideoTitles = !videoTitles.isEmpty ||
            fileReplacements.values.contains { $0.song.videoMetadata?.originalTitle != nil }
        let existingRecords = try (sections.first { $0.kind == 1 }?.records ?? []).compactMap { record -> Data? in
            let index = original.u32(record.offset + 16)
            guard var track = tracksByID[index] else { return nil }
            var data = record.bytes(in: original)
            let path = track.path.lowercased()
            let podcast = podcastUpdates[path]
            var replacements = podcast.map { Self.changedPodcastFields($0, on: track) } ?? []
            let artist = artistOverrides[track.path.lowercased()]
            let video = fileReplacements[index]
            if let video {
                replacements.append((2, video.path))
                if video.song.classification == .music { replacements.append((6, video.song.kind)) }
            }
            if let description = videoDescriptions[path] ?? video.flatMap({ Self.videoDescription($0.song) }) {
                replacements.append((14, description))
            }
            if let title = videoTitles[path] ?? video.flatMap({ $0.song.videoMetadata?.originalTitle == nil ? nil : $0.song.title }) {
                replacements += [(1, title), (27, "")]
            }
            if let artist, track.fields[4] != artist { replacements += [(4, artist), (23, "")] }
            if !replacements.isEmpty {
                let replaced = Set(replacements.map { $0.0 })
                var objects: [Data] = []
                var offset = record.body
                for _ in 0..<original.u32(record.offset + 12) {
                    let object = try Chunk(original, at: offset, before: record.end, tag: "mhod", minimum: 24)
                    if !replaced.contains(original.u32(offset + 12)) { objects.append(object.bytes(in: original)) }
                    offset = object.end
                }
                objects += replacements.compactMap(Self.stringRecord)
                data = record.headerBytes(in: original)
                for object in objects { data.append(object) }
                data.put(data.count, at: 8)
                data.put(objects.count, at: 12)
                for (key, value) in replacements { track.fields[key] = value.isEmpty ? nil : value }
                tracksByID[index] = track
                if let video {
                    data.put(video.song.size, at: 0x24)
                    data.put(video.song.duration, at: 0x28)
                    data.put(video.song.bitRate, at: 0x38)
                    if video.song.classification == .music {
                        data.replaceSubrange(0x18..<0x1c, with: video.song.fourCC.utf8.reversed())
                        data.put(video.song.sampleRate << 16, at: 0x3c)
                        if record.header >= 0x8c { data.put(Int(Float(video.song.sampleRate).bitPattern), at: 0x88) }
                    }
                    if record.header >= 0x130 { data.put(video.song.size, at: 0x12c) }
                } else if record.header >= 0x124, replaced.contains(3) || replaced.contains(4) {
                    data.put(try resolveAlbum(track.fields[3] ?? "", track.fields[4] ?? ""), at: 0x120)
                }
                if artist != nil, record.header >= 0x1e4 { data.put(0, at: 0x1e0) }
            }
            if let correction = episodeNumbers[path] {
                guard record.header >= 0xdc else { throw SyncError("This iPod track cannot store episode numbers.") }
                data.put(correction.season, at: 0xd4)
                data.put(correction.episode, at: 0xd8)
            }
            if record.header >= Self.releaseDateOffset + 4,
               let release = Self.releaseTimestamp(video?.song.releaseDate ?? podcast?.releaseDate)
                ?? videoReleaseDates[path] ?? (video?.song.videoMetadata?.resetReleaseDate == true ? 0 : nil) {
                data.put(release, at: Self.releaseDateOffset)
            }
            if record.header >= 0x164 {
                if removedVideoArtwork.contains(path) {
                    data.put(0, at: 0x160)
                    data.put(0, at: 0x7c)
                    data.put(0, at: 0x80)
                    data[0xa4] = 2
                } else if let link = try artwork(track) {
                    Self.setArtwork(link, on: &data)
                }
            }
            if let state = listening[path], record.header > 0xb2 {
                Self.writeListening(state, to: &data)
            }
            return data
        }

        for addition in additions where addition.replacesTrackID == nil {
            let song = addition.song
            let artist = artistOverrides[addition.path.lowercased()] ?? song.artist
            let albumArtist = song.albumArtist
            let albumID = try resolveAlbum(song.album, albumArtist.isEmpty ? artist : albumArtist)
            let trackID = nextID
            nextID += 1
            let dbID = Self.randomID()
            var fields = [(1, song.title), (2, addition.path), (3, song.album), (4, artist),
                          (5, song.genre), (6, song.kind), (12, song.composer), (22, albumArtist)]
            if song.classification == .tvShow {
                fields += [(19, song.group), (20, song.episode.map(String.init) ?? "")]
            }
            if let description = Self.videoDescription(song) { fields.append((14, description)) }
            if song.classification == .podcast {
                let podcastFields = Self.podcastFields(song)
                let replaced = Set(podcastFields.map { $0.0 })
                fields.removeAll { replaced.contains($0.0) }
                fields += podcastFields
            }
            let children = fields.compactMap(Self.stringRecord)
            var track = Data.record("mhit", header: trackHeader, children: children)
            track.put(children.count, at: 12)
            track.put(trackID, at: 16)
            track.put(1, at: 20)
            track.replaceSubrange(0x18..<0x1c, with: song.fourCC.utf8.reversed())
            track.put(timestamp, at: 0x20)
            track.put(song.size, at: 0x24)
            track.put(song.duration, at: 0x28)
            track.put(song.number, at: 0x2c)
            track.put(song.trackCount, at: 0x30)
            track.put(song.year, at: 0x34)
            track.put(song.bitRate, at: 0x38)
            track.put(song.sampleRate << 16, at: 0x3c)
            track.put(song.disc, at: 0x5c)
            track.put(song.discCount, at: 0x60)
            track.put(timestamp, at: 0x68)
            track.putID(dbID, at: 0x70)
            track.put(0xffff0000, at: 0x7c)
            track.put(Int(Float(song.sampleRate).bitPattern), at: 0x88)
            let release = Self.releaseTimestamp(song.releaseDate) ?? 0
            track.put(release, at: Self.releaseDateOffset)
            track[0xa4] = 2
            track.putID(dbID, at: 0xa8)
            track.put(song.classification.rawValue, at: 0xd0)
            if song.classification != .music {
                track[0xa5] = 1
                track[0xa6] = 1
                track[0xb2] = 2
            }
            if let state = listening[addition.path.lowercased()] { Self.writeListening(state, to: &track) }
            if song.classification == .movie || song.classification == .tvShow { track[0xb1] = 1 }
            track.put(song.season ?? 0, at: 0xd4)
            track.put(song.episode ?? 0, at: 0xd8)
            track.put(albumID, at: 0x120)
            track.replaceSubrange(0x124..<0x12c, with: libraryID)
            track.put(song.size, at: 0x12c)
            track.put(0x80808080, at: 0x134)
            track.put(0x00008080, at: 0x138)
            let entry = Track(id: trackID, persistentID: track.subdata(in: 0x70..<0x78),
                                   fields: Dictionary(uniqueKeysWithValues: fields), size: song.size,
                                   disc: song.disc, number: song.number, artworkID: 0, mediaType: song.classification.rawValue,
                                   season: song.season ?? 0, episode: song.episode ?? 0, releaseTimestamp: release)
            if trackHeader >= 0x164, let link = try artwork(entry) { Self.setArtwork(link, on: &track) }
            newTracks.append(track)
            newEntries.append(entry)
        }

        let allTracks = tracksByID.merging(Dictionary(uniqueKeysWithValues: newEntries.map { ($0.id, $0) })) { existing, _ in existing }
        let tracksByPath = Dictionary((tracks.compactMap { tracksByID[$0.id] } + newEntries).map { ($0.path.lowercased(), $0) },
                                      uniquingKeysWith: { first, _ in first })
        let managedIDs = Set(playlists.map(\.id)).union(removed)
        let newPodcasts = rebuildPodcastIndex || !podcastUpdates.isEmpty ||
            tracks.contains { removedTracks.contains($0.id) && $0.mediaType & ClassicMediaKind.podcast.rawValue != 0 } ||
            newEntries.contains { $0.mediaType == ClassicMediaKind.podcast.rawValue }
        let podcasts = (tracks.compactMap { tracksByID[$0.id] } + newEntries).filter { $0.mediaType & ClassicMediaKind.podcast.rawValue != 0 }
        let podcastID = sections.lazy.filter { $0.kind == 2 || $0.kind == 3 }
            .flatMap(\.records).first { $0.header >= 44 && (original.u32($0.offset + 40) >> 16) == 1 }
            .map { original.subdata(in: $0.offset + 28..<$0.offset + 36) } ?? withUnsafeBytes(of: Self.randomID().littleEndian) { Data($0) }
        var output = root.headerBytes(in: original)
        var outputSections = sections
        if newPodcasts, !sections.contains(where: { $0.kind == 3 }),
           let index = sections.firstIndex(where: { $0.kind == 2 }) {
            let flat = sections[index]
            outputSections.insert(Section(kind: 3, chunk: flat.chunk, list: flat.list, records: flat.records), at: index)
        }
        for section in outputSections {
            guard let list = section.list else {
                output.append(section.chunk.bytes(in: original))
                continue
            }
            var records: [Data]
            switch section.kind {
            case 1: records = existingRecords + newTracks
            case 4: records = section.records.map { $0.bytes(in: original) } + newAlbums
            default:
                guard section.records.filter({ original[$0.offset + 20] & 1 != 0 }).count == 1 else {
                    throw SyncError("The iPod database does not have a single main playlist.")
                }
                let main = section.records.first { original[$0.offset + 20] & 1 != 0 }!
                records = try section.records.compactMap { record in
                    if record.offset == main.offset {
                        return newEntries.isEmpty && artistOverrides.isEmpty && !updatesVideoTitles && removedTracks.isEmpty ? record.bytes(in: original)
                            : try updatePlaylist(record, with: newEntries, allTracks: allTracks, timestamp: timestamp,
                                                 removedTracks: removedTracks)
                    }
                    if newPodcasts, record.header >= 44, original.u32(record.offset + 40) >> 16 == 1 {
                        return nil
                    }
                    let isPodcast = record.header >= 44 && original.u16(record.offset + 42) == 1
                    if record.header >= 36, !isPodcast, managedIDs.contains(original.subdata(in: record.offset + 28..<record.offset + 36)) {
                        return nil
                    }
                    return removedTracks.isEmpty ? record.bytes(in: original)
                        : try updatePlaylist(record, with: [], allTracks: allTracks, timestamp: timestamp,
                                             removedTracks: removedTracks, isMain: false)
                }
                if newPodcasts, !podcasts.isEmpty {
                    let preferences = try playlistPreferences(main)
                    records.append(Self.podcastPlaylist(id: podcastID, members: podcasts, grouped: section.kind == 3,
                                                        header: main.header, timestamp: timestamp,
                                                        preferences: preferences, nextID: &nextID))
                }
                if !playlists.isEmpty {
                    guard main.header >= 50 else { throw SyncError("This iTunesDB uses an older playlist layout.") }
                    let preferences = try playlistPreferences(main)
                    records += playlists.map { update in
                        Self.playlist(update, members: update.paths.compactMap { tracksByPath[$0] },
                                      header: main.header, timestamp: timestamp, preferences: preferences)
                    }
                }
            }
            var data = section.chunk.headerBytes(in: original) + list.headerBytes(in: original)
            data.put(section.kind, at: 12)
            data.put(records.count, at: section.chunk.header + 8)
            for record in records { data.append(record) }
            data.put(data.count, at: 8)
            output.append(data)
        }
        output.put(output.count, at: 8)
        output.put(outputSections.count, at: 20)
        return output
    }

    private static func setArtwork(_ link: ArtworkLink, on track: inout Data) {
        track[0x7c] = 1
        track[0x7d] = 0
        track.put(link.size, at: 0x80)
        track[0xa4] = 1
        track.put(link.id, at: 0x160)
    }

    private static func writeListening(_ state: ClassicListeningState, to track: inout Data) {
        track.put(min(state.milliseconds, track.u32(0x28)), at: 0x6c)
        track[0xa6] = 1
        track[0xb2] = state.played ? 1 : 2
    }

    private func playlistPreferences(_ record: Chunk) throws -> [Data] {
        var position = record.body
        var preferences: [Data] = []
        for _ in 0..<original.u32(record.offset + 12) {
            let object = try Chunk(original, at: position, before: record.end, tag: "mhod", minimum: 24)
            if original.u32(position + 12) == 100 { preferences.append(object.bytes(in: original)) }
            position = object.end
        }
        return preferences
    }

    private static func playlist(_ update: PlaylistUpdate, members: [Track], header: Int, timestamp: Int,
                                 preferences: [Data]) -> Data {
        let objects = [(1, update.name)].compactMap(stringRecord) + preferences
        let items = members.enumerated().map { playlistItem($0.element, position: $0.offset, timestamp: timestamp) }
        var data = Data.record("mhyp", header: header, children: objects + items)
        data.put(objects.count, at: 12)
        data.put(items.count, at: 16)
        data.put(timestamp, at: 24)
        data.replaceSubrange(28..<36, with: update.id)
        data.put(1, at: 40)
        data.put(1, at: 44)
        return data
    }

    // Section 3 uses a show heading followed by its episode rows. Section 2 stores a flat list.
    private static func podcastGroupKey(_ track: Track) -> String {
        track.fields[16].flatMap { $0.isEmpty ? nil : $0 } ?? podcastGroupTitle(track)
    }

    private static func podcastGroupTitle(_ track: Track?) -> String {
        track?.fields[3].flatMap { $0.isEmpty ? nil : $0 } ?? "Podcasts"
    }

    private static func podcastPlaylist(id: Data, members: [Track], grouped: Bool, header: Int,
                                        timestamp: Int, preferences: [Data], nextID: inout Int) -> Data {
        let title = stringRecord((1, "Podcasts"))!
        let objects = [title] + preferences
        let items: [Data]
        if grouped {
            var groups: [Data] = []
            let byShow = Dictionary(grouping: members, by: podcastGroupKey)
            let shows = byShow.values.sorted {
                ($0.first?.fields[3] ?? "", $0.first?.fields[16] ?? "")
                    < ($1.first?.fields[3] ?? "", $1.first?.fields[16] ?? "")
            }
            for episodes in shows {
                let show = podcastGroupTitle(episodes.first)
                let groupID = nextID
                nextID += 1
                var heading = Data.record("mhip", header: 76, children: [stringRecord((1, show))!])
                heading.put(1, at: 12)
                heading.put(256, at: 16)
                heading.put(groupID, at: 20)
                groups.append(heading)
                for track in episodes {
                    var item = playlistItem(track, position: nextID, timestamp: timestamp)
                    item.put(nextID, at: 20)
                    item.put(groupID, at: 32)
                    nextID += 1
                    groups.append(item)
                }
            }
            items = groups
        } else {
            items = members.enumerated().map { playlistItem($0.element, position: $0.offset, timestamp: timestamp) }
        }
        var data = Data.record("mhyp", header: max(header, 50), children: objects + items)
        data.put(objects.count, at: 12)
        data.put(items.count, at: 16)
        data.put(timestamp, at: 24)
        data.replaceSubrange(28..<36, with: id)
        data.put(0x00010001, at: 40)
        data.put(1, at: 44)
        return data
    }

    private static func playlistItem(_ track: Track, position index: Int, timestamp: Int) -> Data {
        var position = Data.record("mhod", header: 44)
        position.put(24, at: 4)
        position.put(100, at: 12)
        position.put(index, at: 24)
        var item = Data.record("mhip", header: 76, children: [position])
        item.put(1, at: 12)
        item.put(track.id, at: 24)
        item.put(timestamp, at: 28)
        item.replaceSubrange(44..<52, with: track.persistentID)
        item.putID(randomID(), at: 60)
        return item
    }

    private func updatePlaylist(_ record: Chunk, with additions: [Track], allTracks: [Int: Track],
                                timestamp: Int, removedTracks: Set<Int> = [], isMain: Bool = true) throws -> Data {
        var offset = record.body
        var objects: [Data] = []
        var sorts: [Int: [Data]] = [:]
        var sortOrder: [Int] = []
        for _ in 0..<original.u32(record.offset + 12) {
            let object = try Chunk(original, at: offset, before: record.end, tag: "mhod", minimum: 24)
            let kind = original.u32(offset + 12)
            if (kind == 52 || kind == 53), object.end - object.body >= 8 {
                let sort = original.u32(object.body)
                if sorts[sort] == nil { sortOrder.append(sort) }
                sorts[sort, default: []].append(object.bytes(in: original))
            } else {
                objects.append(object.bytes(in: original))
            }
            offset = object.end
        }
        let count = original.u32(record.offset + 16)
        var items: [Data] = []
        var members: [Track] = []
        var positions: [Int: Int] = [:]
        for index in 0..<count {
            let item = try Chunk(original, at: offset, before: record.end, tag: "mhip", minimum: 32)
            offset = item.end
            let id = original.u32(item.offset + 24)
            if removedTracks.contains(id) { continue }
            positions[index] = items.count
            items.append(item.bytes(in: original))
            if let track = allTracks[id] { members.append(track) }
            else if isMain {
                throw SyncError("The main playlist refers to a missing track.")
            }
        }
        guard offset == record.end else { throw SyncError("Unexpected data after the main playlist.") }
        if !isMain, items.count == count { return record.bytes(in: original) }
        if items.count != count {
            for index in items.indices {
                var item = items[index]
                var child = item.u32(4)
                for _ in 0..<item.u32(12) {
                    let object = try Chunk(item, at: child, before: item.count, tag: "mhod", minimum: 24)
                    if item.u32(child + 12) == 100, object.end - object.body >= 4 {
                        item.put(index, at: object.body)
                    }
                    child = object.end
                }
                items[index] = item
            }
        }
        for track in additions {
            items.append(Self.playlistItem(track, position: items.count, timestamp: timestamp))
            members.append(track)
        }
        for sort in sortOrder {
            if members.count == items.count, let rebuilt = Self.sortRecords(kind: sort, members: members) {
                objects.append(contentsOf: rebuilt)
            } else {
                for var index in sorts[sort] ?? [] {
                    let kind = index.u32(12)
                    let oldCount = index.u32(28)
                    if !removedTracks.isEmpty {
                        if kind == 52, index.count == 72 + oldCount * 4 {
                            let filtered = (0..<oldCount).compactMap { positions[index.u32(72 + $0 * 4)] }
                            let order = filtered + Array((items.count - additions.count)..<items.count)
                            index = Data(index.prefix(72)) + Data(count: order.count * 4)
                            index.put(order.count, at: 28)
                            for (position, member) in order.enumerated() { index.put(member, at: 72 + position * 4) }
                        } else if kind == 53, index.count == 40 + oldCount * 12,
                                  let order = sorts[sort]?.first(where: { $0.u32(12) == 52 }),
                                  order.count == 72 + order.u32(28) * 4 {
                            var jumps = Data(index.prefix(40))
                            var total = 0
                            for group in 0..<oldCount {
                                let start = index.u32(44 + group * 12)
                                let end = min(start + index.u32(48 + group * 12), order.u32(28))
                                guard start < end else { continue }
                                let kept = (start..<end).filter { positions[order.u32(72 + $0 * 4)] != nil }.count
                                if kept > 0 {
                                    var row = Data(count: 12)
                                    row.put(index.u32(40 + group * 12), at: 0)
                                    row.put(total, at: 4)
                                    row.put(kept, at: 8)
                                    jumps.append(row)
                                    total += kept
                                }
                            }
                            if !additions.isEmpty {
                                var row = Data(count: 12)
                                row.put(35, at: 0)
                                row.put(total, at: 4)
                                row.put(additions.count, at: 8)
                                jumps.append(row)
                            }
                            jumps.put((jumps.count - 40) / 12, at: 28)
                            index = jumps
                        } else { continue }
                    } else if kind == 52, index.count == 72 + oldCount * 4 {
                        index.append(Data(count: additions.count * 4))
                        for addition in additions.indices {
                            index.put(count + addition, at: 72 + (oldCount + addition) * 4)
                        }
                        index.put(oldCount + additions.count, at: 28)
                    } else if kind == 53, !additions.isEmpty, index.count == 40 + oldCount * 12 {
                        let end = index.count
                        index.append(Data(count: 12))
                        index.put(35, at: end)
                        index.put(count, at: end + 4)
                        index.put(additions.count, at: end + 8)
                        index.put(oldCount + 1, at: 28)
                    }
                    index.put(index.count, at: 8)
                    objects.append(index)
                }
            }
        }
        var playlist = record.headerBytes(in: original)
        playlist.put(objects.count, at: 12)
        playlist.put(items.count, at: 16)
        for child in objects + items { playlist.append(child) }
        playlist.put(playlist.count, at: 8)
        return playlist
    }

    private static func sortRecords(kind: Int, members: [Track]) -> [Data]? {
        let fields = [3: [27, 1], 4: [28, 3], 5: [23, 4], 7: [5], 18: [30, 12]]
        guard let tags = fields[kind] else { return nil }
        let keys = members.map { track in
            tags.compactMap { track.fields[$0] }.first { !$0.isEmpty } ?? ""
        }
        let sorted = members.indices.sorted { lhs, rhs in
            let comparison = keys[lhs].localizedStandardCompare(keys[rhs])
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if kind == 4 {
                let left = (members[lhs].disc, members[lhs].number)
                let right = (members[rhs].disc, members[rhs].number)
                if left != right { return left < right }
            }
            return lhs < rhs
        }
        var index = Data.record("mhod", header: 72 + sorted.count * 4)
        index.put(24, at: 4)
        index.put(52, at: 12)
        index.put(kind, at: 24)
        index.put(sorted.count, at: 28)
        var groups: [(letter: Int, start: Int, count: Int)] = []
        for (position, member) in sorted.enumerated() {
            index.put(member, at: 72 + position * 4)
            let first = keys[member].folding(options: [.diacriticInsensitive], locale: nil).uppercased().utf16.first ?? 35
            let letter = (65...90).contains(first) ? Int(first) : 35
            if groups.last?.letter == letter {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((letter, position, 1))
            }
        }
        var jumps = Data.record("mhod", header: 40 + groups.count * 12)
        jumps.put(24, at: 4)
        jumps.put(53, at: 12)
        jumps.put(kind, at: 24)
        jumps.put(groups.count, at: 28)
        for (index, group) in groups.enumerated() {
            let offset = 40 + index * 12
            jumps.put(group.letter, at: offset)
            jumps.put(group.start, at: offset + 4)
            jumps.put(group.count, at: offset + 8)
        }
        return [index, jumps]
    }

    private static func fields(_ data: Data, record: Chunk) throws -> [Int: String] {
        var offset = record.body
        var strings: [Int: String] = [:]
        for _ in 0..<data.u32(record.offset + 12) {
            let object = try Chunk(data, at: offset, before: record.end, tag: "mhod", minimum: 24)
            let kind = data.u32(offset + 12)
            if kind == 15 || kind == 16 {
                strings[kind] = String(data: data[object.body..<object.end], encoding: .utf8)
            } else if object.end - object.body >= 16 {
                let length = data.u32(object.body + 4)
                let start = object.body + 16
                let encoding: String.Encoding? = switch data.u32(object.body) {
                case 1: .utf16LittleEndian
                case 2: .utf8
                default: nil
                }
                if let encoding, length <= object.end - start,
                   let string = String(data: data[start..<(start + length)], encoding: encoding) {
                    strings[kind] = string
                }
            }
            offset = object.end
        }
        return strings
    }

    static func videoDescription(_ song: Song) -> String? {
        song.videoMetadata?.overview.map { String($0.prefix(4000)) }
    }

    static func podcastFields(_ song: Song) -> [(Int, String)] {
        var fields = [(1, song.title), (3, song.album), (4, song.artist), (5, song.genre)]
        if let metadata = song.podcastMetadata {
            fields += [(15, metadata.enclosure), (16, metadata.feed)]
            if let summary = metadata.summary, !summary.isEmpty { fields.append((14, summary)) }
        }
        return fields.filter { !$0.1.isEmpty }
    }

    static func changedPodcastFields(_ song: Song, on track: Track) -> [(Int, String)] {
        podcastFields(song).filter { field, value in
            let expected = field == 15 || field == 16 ? value : value.precomposedStringWithCanonicalMapping
            return !(track.fields[field] ?? "").utf8.elementsEqual(expected.utf8)
        }
    }

    static func stringRecord(_ field: (Int, String)) -> Data? {
        if field.0 == 15 || field.0 == 16 {
            var data = Data.record("mhod", header: 24, children: [Data(field.1.utf8)])
            data.put(field.0, at: 12)
            return data
        }
        // Firmware fonts can render a precomposed letter without placing a combining mark.
        // The media path must still refer to the exact filename on disk.
        let value = field.0 == 2 ? field.1 : field.1.precomposedStringWithCanonicalMapping
        guard !value.isEmpty, let encoded = value.data(using: .utf16LittleEndian) else { return nil }
        var data = Data.record("mhod", header: 40, children: [encoded])
        data.put(24, at: 4)
        data.put(field.0, at: 12)
        data.put(1, at: 24)
        data.put(encoded.count, at: 28)
        data.put(1, at: 32)
        return data
    }

    private static func albumKey(_ title: String, _ artist: String) -> [String] {
        [title.lowercased(), artist.lowercased()]
    }

    private static func randomID() -> UInt64 { UInt64.random(in: 1...UInt64.max) }
}
