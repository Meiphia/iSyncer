import AVFoundation
import Foundation

public enum ClassicMediaKind: Int, Codable, CaseIterable, Sendable {
    case music = 1, movie = 2, podcast = 4, audiobook = 8, tvShow = 64
}

public struct ClassicVideo: Sendable {
    public let url: URL
    public let title: String
    public let show: String
    public let season: Int
    public let episode: Int
    public let year: Int

    public init(url: URL, title: String, show: String = "", season: Int = 0, episode: Int = 0, year: Int = 0) {
        self.url = url
        self.title = title
        self.show = show
        self.season = season
        self.episode = episode
        self.year = year
    }
}

public struct PodcastMetadata: Codable, Equatable, Sendable {
    public let feed: String
    public let enclosure: String
    public let title: String?
    public let author: String?
    public let summary: String?
    public var publishedAt: Date?

    public init(feed: String, enclosure: String, title: String? = nil, author: String? = nil, summary: String? = nil,
                publishedAt: Date? = nil) {
        self.feed = feed
        self.enclosure = enclosure
        self.title = title
        self.author = author
        self.summary = summary
        self.publishedAt = publishedAt
    }

    public static func sidecar(for url: URL) -> URL { url.appendingPathExtension("podcast.json") }

    public static func load(for url: URL) -> PodcastMetadata? {
        guard let data = try? Data(contentsOf: sidecar(for: url)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public struct Song: Codable, Equatable, Identifiable, Sendable {
    public var id: URL { url }
    public var mediaType: ClassicMediaKind { classification }
    public let url: URL
    public private(set) var title: String
    public let artist: String
    public let album: String
    public let albumArtist: String
    public let genre: String
    public let composer: String
    public let duration: Int
    public let size: Int
    public let number: Int
    public let trackCount: Int
    public let disc: Int
    public let discCount: Int
    public let year: Int
    let bitRate: Int
    let sampleRate: Int
    let kind: String
    let fourCC: String
    public let modificationDate: Date
    var mediaKind: ClassicMediaKind? = nil
    var podcastMetadata: PodcastMetadata? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var previousVideoEncoding: URL? = nil
    var originalSource: URL? = nil
    var videoMetadata: VideoMetadata? = nil
    var classification: ClassicMediaKind { mediaKind ?? .music }
    var group: String { album }
    var videoSyncKeys: [String] {
        switch classification {
        case .tvShow:
            return [title, videoMetadata?.originalTitle].compactMap { $0 }.map {
                Self.videoSyncKey(tv: true, show: album, season: season ?? 0, episode: episode ?? 0, title: $0)
            }
        case .movie:
            return [title, videoMetadata?.originalTitle].compactMap { $0 }.map {
                Self.videoSyncKey(tv: false, show: "", season: 0, episode: 0, title: $0)
            }
        default: return []
        }
    }

    public static func videoSyncKey(tv: Bool, show: String, season: Int, episode: Int, title: String) -> String {
        let text = tv && episode > 0 ? show : tv ? show + "\u{1f}" + title : title
        let prefix = tv ? "tv:\(season):\(episode):" : "movie:"
        return prefix + text.precomposedStringWithCanonicalMapping.lowercased()
    }
    var releaseDate: Date? { podcastMetadata?.publishedAt ?? videoMetadata?.releaseDate }
    var hasVideoArtwork: Bool { videoMetadata?.artworkURL != nil || videoMetadata?.embeddedArtwork != nil }

    public func applyingVideoEdit(_ edit: VideoMetadataEdit?) -> Song {
        guard let edit else { return self }
        var song = self
        var metadata = videoMetadata ?? VideoMetadata()
        if let title = edit.title {
            metadata.originalTitle = self.title
            song.title = title
        }
        if let releaseDate = edit.releaseDate { metadata.releaseDate = releaseDate }
        if let overview = edit.overview { metadata.overview = overview }
        metadata.resetReleaseDate = edit.resetReleaseDate
        if let artwork = edit.artwork {
            metadata.artworkURL = nil
            metadata.embeddedArtwork = artwork
            metadata.customArtwork = true
        } else if edit.resetArtwork == true {
            metadata.customArtwork = true
        }
        song.videoMetadata = metadata
        return song
    }

    public func replacingVideoEncoding(at previousURL: URL) -> Song {
        var song = self
        song.previousVideoEncoding = previousURL
        return song
    }

    var matchKey: [String] {
        Self.matchKey(title: title, artist: artist, album: album, size: size, disc: disc, number: number)
    }

    static func matchKey(title: String, artist: String, album: String, size: Int, disc: Int, number: Int) -> [String] {
        [title, artist, album].map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        + [String(size), String(disc), String(number)]
    }
}

public struct LocalLibrary: Codable, Sendable {
    public let songs: [Song]
    public let skipped: Int
    public var failures: [MediaScanFailure]? = nil
}

public struct MediaScanFailure: Codable, Sendable {
    public let url: URL
    public let reason: String
}

public struct LibraryCache: Codable, Sendable {
    private let version: Int
    private let folders: [URL]
    private let library: LocalLibrary

    public init(folders: [URL], library: LocalLibrary) {
        self.version = 1
        self.folders = folders
        self.library = library
    }

    public static func load(from file: URL) -> LibraryCache? {
        guard let data = try? Data(contentsOf: file),
              let cache = try? PropertyListDecoder().decode(Self.self, from: data),
              cache.version == 1 else { return nil }
        return cache
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public func snapshot(for folders: [URL]) -> LocalLibrary? {
        self.folders == folders ? library : nil
    }

    fileprivate var tracksByURL: [URL: Song] {
        Dictionary(library.songs.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum ScanProgress: Sendable {
    case finding(count: Int, folder: String)
    case reading(processed: Int, total: Int, accepted: Int, skipped: Int, filename: String)
}

public enum LibraryScanner {
    private static let playable: Set<String> = ["mp3", "m4a", "m4b", "wav", "aif", "aiff"]
    private static let otherAudio: Set<String> = ["flac", "ogg", "opus", "aac", "m4p", "wma", "ape", "alac", "dsf", "m4b"]
    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    public static func scan(_ folders: [URL], cache: LibraryCache? = nil,
                            progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> LocalLibrary {
        let files = try findFiles(in: folders, progress: progress)
        return try await scanFiles(files, cache: cache, progress: progress)
    }

    public static func scanFiles(_ files: [URL], cache: LibraryCache? = nil,
                                 progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> LocalLibrary {
        let cached = cache?.tracksByURL ?? [:]
        var songs: [Song] = []
        var candidates: [URL] = []
        var skipped = 0
        var failures: [MediaScanFailure] = []
        for url in files {
            try Task.checkCancellation()
            guard playable.contains(url.pathExtension.lowercased()) else {
                skipped += 1
                failures.append(.init(url: url, reason: "Unsupported audio file type."))
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                skipped += 1
                failures.append(.init(url: url, reason: "File is missing or unreadable."))
                continue
            }
            if let song = cached[url.standardizedFileURL], song.size == values.fileSize,
               song.modificationDate == values.contentModificationDate {
                songs.append(song)
            } else {
                candidates.append(url)
            }
        }
        var processed = 0
        var queued = 0
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        if let first = candidates.first {
            progress(.reading(processed: 0, total: candidates.count, accepted: songs.count, skipped: skipped,
                              filename: first.lastPathComponent))
        }
        try await withThrowingTaskGroup(of: (URL, Song?, String?).self) { group in
            // Keep several metadata reads in flight without flooding external disks.
            for file in candidates.prefix(4) {
                group.addTask { try await scanFile(file) }
                queued += 1
            }
            for try await (file, song, reason) in group {
                try Task.checkCancellation()
                if let song { songs.append(song) }
                else {
                    skipped += 1
                    failures.append(.init(url: file, reason: reason ?? "Could not read audio."))
                }
                processed += 1
                let now = clock.now
                if now >= nextUpdate || processed == candidates.count {
                    progress(.reading(processed: processed, total: candidates.count, accepted: songs.count,
                                      skipped: skipped, filename: file.lastPathComponent))
                    nextUpdate = now + .milliseconds(125)
                }
                if queued < candidates.count {
                    let next = candidates[queued]
                    group.addTask { try await scanFile(next) }
                    queued += 1
                }
            }
        }
        songs.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return LocalLibrary(songs: songs, skipped: skipped, failures: failures)
    }

    public static func podcast(_ song: Song, show: String, metadata: PodcastMetadata? = nil) -> Song {
        let metadata = metadata ?? PodcastMetadata.load(for: song.url)
        // Older imports have only their audio tags and folder name. Give each show a stable group key.
        let key = Data(show.precomposedStringWithCanonicalMapping.utf8).map { String(format: "%02x", $0) }.joined()
        let storedFeed = try? String(contentsOf: song.url.deletingLastPathComponent().appending(path: ".feed-url"), encoding: .utf8)
        let episodeKey = Data(song.url.lastPathComponent.precomposedStringWithCanonicalMapping.utf8)
            .map { String(format: "%02x", $0) }.joined()
        let details = metadata ?? PodcastMetadata(feed: storedFeed ?? "https://isyncer.invalid/podcasts/\(key)",
                                                  enclosure: "https://isyncer.invalid/episodes/\(key)/\(episodeKey)")
        return Song(url: song.url, title: details.title ?? song.title, artist: details.author ?? song.artist, album: show,
             albumArtist: song.albumArtist, genre: "Podcast", composer: song.composer,
             duration: song.duration, size: song.size, number: song.number, trackCount: song.trackCount,
             disc: song.disc, discCount: song.discCount, year: song.year, bitRate: song.bitRate,
             sampleRate: song.sampleRate, kind: song.kind, fourCC: song.fourCC,
             modificationDate: song.modificationDate, mediaKind: .podcast, podcastMetadata: details)
    }

    public static func audiobook(_ song: Song, book: String) -> Song {
        Song(url: song.url, title: song.title, artist: song.artist, album: book,
             albumArtist: song.albumArtist, genre: "Audiobook", composer: song.composer,
             duration: song.duration, size: song.size, number: song.number, trackCount: song.trackCount,
             disc: song.disc, discCount: song.discCount, year: song.year, bitRate: song.bitRate,
             sampleRate: song.sampleRate, kind: song.kind, fourCC: song.fourCC,
             modificationDate: song.modificationDate, mediaKind: .audiobook)
    }

    public static func scanVideo(_ video: ClassicVideo, converted: Bool = false, metadataSource: URL? = nil) async throws -> Song {
        let url = video.url
        let values = try url.resourceValues(forKeys: Set(keys))
        guard ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...Int(UInt32.max)).contains(size),
              let modified = values.contentModificationDate else {
            throw SyncError("Unsupported video container.")
        }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTracks.count == 1, audioTracks.count == 1,
              let picture = videoTracks.first, let sound = audioTracks.first else {
            throw SyncError("Video must have one picture track and one audio track.")
        }
        let pictureFormats = try await picture.load(.formatDescriptions)
        let audioFormats = try await sound.load(.formatDescriptions)
        let fps = try await picture.load(.nominalFrameRate)
        let videoRate = try await picture.load(.estimatedDataRate)
        let audioRate = try await sound.load(.estimatedDataRate)
        let duration = try await asset.load(.duration).seconds
        guard pictureFormats.count == 1, audioFormats.count == 1,
              let format = pictureFormats.first, compatibleVideo(format, converted: converted),
              let audio = audioFormats.first, CMFormatDescriptionGetMediaSubType(audio) == kAudioFormatMPEG4AAC,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audio)?.pointee,
              stream.mSampleRate > 0, stream.mSampleRate <= 48_000, (1...2).contains(stream.mChannelsPerFrame),
              fps > 0, fps <= 30, videoRate > 0, videoRate <= 2_500_000, audioRate <= 160_000,
              duration.isFinite, duration > 0, duration * 1000 < Double(UInt32.max) else {
            throw SyncError("Video requires Classic-compatible H.264 Baseline and AAC-LC audio.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.width <= 640, dimensions.height > 0, dimensions.height <= 480 else {
            throw SyncError("Video exceeds the Classic’s 640 × 480 limit.")
        }
        let metadata = await VideoMetadata.read(from: metadataSource ?? url, isEpisode: !video.show.isEmpty)
        return Song(url: url, title: video.title, artist: video.show, album: video.show, albumArtist: "",
                    genre: "", composer: "", duration: Int((duration * 1000).rounded()), size: size,
                    number: 0, trackCount: 0, disc: 0, discCount: 0, year: video.year,
                    bitRate: Int(videoRate / 1000), sampleRate: Int(stream.mSampleRate),
                    kind: converted ? "MPEG-4 video file" : "H.264 video file", fourCC: "M4V ", modificationDate: modified,
                    mediaKind: video.show.isEmpty ? .movie : .tvShow, season: video.season, episode: video.episode,
                    originalSource: metadataSource, videoMetadata: metadata)
    }

    private static func compatibleVideo(_ format: CMFormatDescription, converted: Bool) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if converted, codec == kCMVideoCodecType_MPEG4Video { return true }
        guard codec == kCMVideoCodecType_H264,
              let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Data], let avc = atoms["avcC"], avc.count >= 4 else { return false }
        return avc[1] == 66 && avc[3] <= 30
    }

    private static func findFiles(in folders: [URL], progress: @Sendable (ScanProgress) -> Void) throws -> [URL] {
        var seen: Set<URL> = []
        var files: [URL] = []
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for folder in folders {
            progress(.finding(count: seen.count, folder: folder.lastPathComponent))
            var scanError: Error?
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                               errorHandler: { _, error in
                                                                   scanError = error
                                                                   return false
                                                               }) else {
                throw SyncError("Could not open \(folder.lastPathComponent).")
            }
            for case let url as URL in entries {
                try Task.checkCancellation()
                let ext = url.pathExtension.lowercased()
                if playable.contains(ext) || otherAudio.contains(ext),
                   let values = try? url.resourceValues(forKeys: Set(keys)),
                   values.isRegularFile == true, values.isSymbolicLink != true,
                   seen.insert(url.standardizedFileURL).inserted {
                    files.append(url)
                }
                let now = clock.now
                if now >= nextUpdate {
                    progress(.finding(count: seen.count, folder: folder.lastPathComponent))
                    nextUpdate = now + .milliseconds(125)
                }
            }
            if let scanError { throw scanError }
        }
        return files
    }

    private static func scanFile(_ file: URL) async throws -> (URL, Song?, String?) {
        try Task.checkCancellation()
        guard playable.contains(file.pathExtension.lowercased()),
              let values = try? file.resourceValues(forKeys: Set(keys)) else { return (file, nil, "File is missing or unreadable.") }
        do { return (file, try await read(file, values: values), nil) }
        catch { return (file, nil, error.localizedDescription) }
    }

    private static func read(_ url: URL, values: URLResourceValues) async throws -> Song {
        let audio = try AVAudioFile(forReading: url)
        let format = audio.fileFormat
        let details = format.streamDescription.pointee
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 48_000,
              (1...2).contains(format.channelCount),
              let size = values.fileSize, size > 0, size <= Int(UInt32.max),
              let date = values.contentModificationDate else { throw SyncError("Unsupported audio format.") }
        let ext = url.pathExtension.lowercased()
        let kind: String
        let code: String
        switch (ext, details.mFormatID) {
        case ("mp3", kAudioFormatMPEGLayer3): (kind, code) = ("MPEG audio file", "MP3 ")
        case ("m4a", kAudioFormatMPEG4AAC), ("m4b", kAudioFormatMPEG4AAC): (kind, code) = ("AAC audio file", "M4A ")
        case ("m4a", kAudioFormatAppleLossless) where details.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData:
            (kind, code) = ("Apple Lossless audio file", "M4A ")
        case ("wav", kAudioFormatLinearPCM) where details.mBitsPerChannel == 16:
            (kind, code) = ("WAV audio file", "WAV ")
        case ("aif", kAudioFormatLinearPCM), ("aiff", kAudioFormatLinearPCM):
            guard details.mBitsPerChannel == 16 else { throw SyncError("Unsupported AIFF bit depth.") }
            (kind, code) = ("AIFF audio file", "AIFF")
        default: throw SyncError("Unsupported audio codec.")
        }
        let seconds = Double(audio.length) / sampleRate
        guard seconds.isFinite, seconds > 0, seconds * 1000 < Double(UInt32.max) else {
            throw SyncError("Unsupported track duration.")
        }

        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []
        func text(_ identifiers: [AVMetadataIdentifier]) async -> String {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue) {
                        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { return clean }
                    }
                }
            }
            return ""
        }
        func pair(_ identifiers: [AVMetadataIdentifier]) async -> (Int, Int) {
            let parts = await text(identifiers).split(separator: "/", maxSplits: 1)
            if let first = parts.first, let number = Int(first) {
                let total = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
                return (max(0, number), max(0, total))
            }
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                    if let data = try? await item.load(.dataValue), data.count >= 6 {
                        return (Int(data[2]) << 8 | Int(data[3]), Int(data[4]) << 8 | Int(data[5]))
                    }
                }
            }
            return (0, 0)
        }
        let title = await text([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        let track = await pair([.id3MetadataTrackNumber, .iTunesMetadataTrackNumber])
        let disc = await pair([.id3MetadataPartOfASet, .iTunesMetadataDiscNumber])
        let dateTag = await text([.commonIdentifierCreationDate, .id3MetadataYear, .iTunesMetadataReleaseDate])
        return await Song(url: url, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                          artist: text([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist]),
                          album: text([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum]),
                          albumArtist: text([.id3MetadataBand, .iTunesMetadataAlbumArtist]),
                          genre: text([.commonIdentifierType, .id3MetadataContentType, .iTunesMetadataUserGenre]),
                          composer: text([.id3MetadataComposer, .iTunesMetadataComposer]),
                          duration: Int((seconds * 1000).rounded()), size: size, number: track.0,
                          trackCount: track.1, disc: disc.0, discCount: disc.1,
                          year: Int(dateTag.prefix(4)) ?? 0,
                          bitRate: Int((Double(size) * 0.008 / seconds).rounded()), sampleRate: Int(sampleRate),
                          kind: kind, fourCC: code, modificationDate: date)
    }
}
