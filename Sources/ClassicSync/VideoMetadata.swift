import AVFoundation
import Foundation
import ImageIO

public struct VideoMetadataEdit: Codable, Equatable, Sendable {
    public var title: String?
    public var releaseDate: Date?
    public var artwork: Data?
    public var resetArtwork: Bool?
    public var resetReleaseDate: Bool?
    public var overview: String?

    public init(title: String? = nil, releaseDate: Date? = nil, artwork: Data? = nil,
                resetArtwork: Bool? = nil, resetReleaseDate: Bool? = nil, overview: String? = nil) {
        self.title = title
        self.releaseDate = releaseDate
        self.artwork = artwork
        self.resetArtwork = resetArtwork
        self.resetReleaseDate = resetReleaseDate
        self.overview = overview
    }

    public static func detected(at url: URL, isEpisode: Bool) async -> Self {
        let metadata = await VideoMetadata.read(from: url, isEpisode: isEpisode)
        return Self(releaseDate: metadata.releaseDate,
                    artwork: metadata.artworkData, overview: metadata.overview)
    }

    public static func loadArtwork(from url: URL) -> Data? { MediaArtwork.imageData(at: url) }

    public func changes(to incoming: Self) -> [SyncMetadataChange] {
        func date(_ value: Date?) -> String? {
            value.map { String(ISO8601DateFormatter().string(from: $0).prefix(10)) }
        }
        var changes = [
            ("Title", title, incoming.title),
            ("Release date", date(releaseDate), date(incoming.releaseDate)),
            ("Description", overview, incoming.overview)
        ].compactMap { field, before, after -> SyncMetadataChange? in
            guard let after, after != before else { return nil }
            return .init(field: field, before: before ?? "", after: after)
        }
        if let cover = incoming.artwork, cover != artwork {
            changes.append(.init(field: "Cover", before: artwork == nil ? "" : "Current artwork", after: "New artwork",
                                 beforeImage: artwork.flatMap(ArtworkWriter.previewImage),
                                 afterImage: ArtworkWriter.previewImage(cover)))
        }
        return changes
    }

    public static func isValidArtwork(_ data: Data) -> Bool {
        CGImageSourceCreateWithData(data as CFData, nil) != nil
    }
}

struct VideoMetadata: Codable, Equatable, Sendable {
    var releaseDate: Date?
    var artworkURL: URL?
    var embeddedArtwork: Data?
    var originalTitle: String?
    var customArtwork: Bool? = nil
    var resetReleaseDate: Bool? = nil
    var overview: String?

    var artworkData: Data? { artworkURL.flatMap(MediaArtwork.imageData) ?? embeddedArtwork }

    static func read(from url: URL, isEpisode: Bool) async -> Self {
        let stem = url.deletingPathExtension()
        let folder = url.deletingLastPathComponent()
        let nfo = stem.appendingPathExtension("nfo")
        let localNFO = readNFO(nfo)
        let movieNFO = isEpisode ? nil : readNFO(folder.appending(path: "movie.nfo"))
        let dateKeys = isEpisode ? ["aired", "premiered"] : ["premiered", "releasedate"]
        let nfoDate = [localNFO, movieNFO].compactMap { root in
            dateKeys.lazy.compactMap { root?.elements(forName: $0).first?.stringValue.flatMap(parseDate) }.first
        }.first
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        var taggedDate: Date?
        for item in metadata where item.identifier == .iTunesMetadataReleaseDate {
            taggedDate = try? await item.load(.dateValue)
            if taggedDate == nil, let text = try? await item.load(.stringValue) {
                taggedDate = parseDate(text)
            }
            if taggedDate != nil { break }
        }
        var coverStems = [stem, folder.appending(path: stem.lastPathComponent + "-thumb"),
                          folder.appending(path: stem.lastPathComponent + "-poster")]
        coverStems += ["poster", "cover", "folder"].map { folder.appending(path: $0) }
        if isEpisode, folder.lastPathComponent.range(of: #"^(?:season|series|s)[ ._-]*\d{1,2}$"#,
                                                     options: [.regularExpression, .caseInsensitive]) != nil {
            let show = folder.deletingLastPathComponent()
            coverStems += ["poster", "cover", "folder", "tvshow"].map { show.appending(path: $0) }
        }
        let candidates = coverStems.flatMap { stem in
            ["jpg", "jpeg", "png"].map { stem.appendingPathExtension($0) }
        }
        let artworkURL = candidates.first { MediaArtwork.imageData(at: $0) != nil }
        var embeddedArtwork: Data?
        if artworkURL == nil {
            for item in metadata where item.identifier == .iTunesMetadataCoverArt || item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), (1...8_388_608).contains(data.count) {
                    embeddedArtwork = data
                    break
                }
            }
        }
        var overview = localNFO?.elements(forName: "plot").first?.stringValue
            ?? movieNFO?.elements(forName: "plot").first?.stringValue
        if overview == nil {
            for item in metadata where item.commonKey == .commonKeyDescription {
                overview = try? await item.load(.stringValue)
                if overview != nil { break }
            }
        }
        return Self(releaseDate: nfoDate ?? taggedDate, artworkURL: artworkURL,
                    embeddedArtwork: embeddedArtwork, overview: overview)
    }

    private static func readNFO(_ url: URL) -> XMLElement? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...262_144).contains(size),
              let data = try? Data(contentsOf: url),
              let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              xml.dtd == nil, let root = xml.rootElement() else { return nil }
        return root
    }

    private static func parseDate(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
