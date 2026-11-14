import Foundation

/// Finds publicly hosted covers without sending local artwork or file paths.
actor DiscordAlbumArt {
    static let shared = DiscordAlbumArt()

    struct Artwork: Sendable {
        let image: URL
        var albumPage: URL? = nil
    }

    private struct Catalog: Decodable {
        struct Album: Decodable {
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: URL?
            let collectionViewUrl: URL?
        }
        let results: [Album]
    }

    private struct ReleaseGroups: Decodable {
        let groups: [ReleaseGroup]
        enum CodingKeys: String, CodingKey { case groups = "release-groups" }
    }

    private struct ReleaseGroup: Decodable {
        struct Credit: Decodable { let name: String; let joinphrase: String? }
        struct Release: Decodable { let id: UUID }

        let id: UUID
        let title: String
        let credits: [Credit]
        let releases: [Release]?
        enum CodingKeys: String, CodingKey {
            case id, title, releases
            case credits = "artist-credit"
        }

        var artist: String { credits.map { $0.name + ($0.joinphrase ?? "") }.joined() }
    }

    private struct Cover: Decodable {
        struct Image: Decodable {
            let front: Bool
            let thumbnails: [String: URL]
        }
        let images: [Image]
    }

    private struct Key: Hashable {
        let artist: String
        let album: String
    }

    private struct CacheEntry {
        let artwork: Artwork?
        let expires: Date
    }

    private var cache: [Key: CacheEntry] = [:]
    private var inFlight: [Key: Task<Artwork?, Never>] = [:]
    private var nextSearch = ContinuousClock.now

    func lookup(albumArtist: String, artist: String, album: String) async -> Artwork? {
        for credit in Self.artistCandidates(albumArtist: albumArtist, artist: artist) {
            guard !Task.isCancelled else { return nil }
            if let cover = await lookup(credit: credit, album: album) { return cover }
        }
        return nil
    }

    static func artistCandidates(albumArtist: String, artist: String) -> [String] {
        var seen = Set<String>()
        return [albumArtist, artist].compactMap { tag in
            let credit = catalogCredit(tag).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(credit)
            return !key.isEmpty && seen.insert(key).inserted ? credit : nil
        }
    }

    private func lookup(credit artist: String, album: String) async -> Artwork? {
        let key = Key(artist: Self.normalize(Self.catalogCredit(artist)), album: Self.normalize(album))
        guard !key.artist.isEmpty, !key.album.isEmpty else { return nil }
        if let entry = cache[key], entry.expires > Date() { return entry.artwork }
        if let task = inFlight[key] { return await task.value }

        let task = Task<Artwork?, Never> {
            if let artwork = try? await Self.fetchCatalog(artist: artist, album: album) { return artwork }
            let searchTime = max(ContinuousClock.now, nextSearch)
            nextSearch = searchTime + .milliseconds(1100)
            try? await Task.sleep(until: searchTime, clock: .continuous)
            return (try? await Self.fetch(artist: artist, album: album)).map { Artwork(image: $0) }
        }
        inFlight[key] = task
        let artwork = await task.value
        inFlight[key] = nil
        if cache.count >= 512 { cache.removeAll() }
        cache[key] = CacheEntry(artwork: artwork, expires: Date().addingTimeInterval(artwork == nil ? 300 : 86_400))
        return artwork
    }

    private static func fetchCatalog(artist: String, album: String) async throws -> Artwork? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        let local = Locale.current.region?.identifier ?? "US"
        for region in local == "US" ? ["US"] : [local, "US"] {
            components.queryItems = [
                .init(name: "term", value: "\(artist) \(album)"),
                .init(name: "media", value: "music"),
                .init(name: "entity", value: "album"),
                .init(name: "country", value: region),
                .init(name: "limit", value: "25")
            ]
            guard let url = components.url else { continue }
            if let data = try? await request(url), let art = try? catalogCover(in: data, artist: artist, album: album) {
                return art
            }
        }
        return nil
    }

    private static func fetch(artist: String, album: String) async throws -> URL? {
        func quote(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/release-group/"
        let titles = albumTitles(album).map { "releasegroup:\(quote($0))" }.joined(separator: " OR ")
        components.queryItems = [
            URLQueryItem(name: "query", value: "(\(titles)) AND artist:\(quote(artist))"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let url = components.url, let data = try await request(url) else { return nil }
        for endpoint in try coverEndpoints(in: data, artist: artist, album: album) {
            if let coverData = try? await request(endpoint), let cover = try? frontCover(in: coverData),
               let direct = await directImageURL(cover) { return direct }
        }
        return nil
    }

    static func catalogCover(in data: Data, artist: String, album: String) throws -> Artwork? {
        for result in try JSONDecoder().decode(Catalog.self, from: data).results {
            guard let name = result.collectionName, normalize(name) == normalize(album),
                  let credit = result.artistName, normalize(catalogCredit(credit)) == normalize(catalogCredit(artist)),
                  let image = result.artworkUrl100, image.scheme == "https",
                  image.host()?.hasSuffix(".mzstatic.com") == true,
                  let page = result.collectionViewUrl, page.scheme == "https",
                  ["music.apple.com", "itunes.apple.com"].contains(page.host() ?? "") else { continue }
            return Artwork(image: image, albumPage: page)
        }
        return nil
    }

    private static func directImageURL(_ url: URL) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // Inspect the final response without downloading the full image.
        guard let (_, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true, http.url?.scheme == "https" else { return nil }
        return http.url
    }

    static func coverEndpoints(in data: Data, artist: String, album: String) throws -> [URL] {
        let groups = try JSONDecoder().decode(ReleaseGroups.self, from: data).groups
        let artistKey = normalize(catalogCredit(artist))
        let credited = groups.filter { normalize(catalogCredit($0.artist)) == artistKey }
        for title in albumTitles(album) {
            let matches = credited.filter { normalize($0.title) == normalize(title) }
            guard !matches.isEmpty else { continue }
            guard Set(matches.map(\.id)).count == 1, let group = matches.first else { return [] }
            let base = URL(string: "https://coverartarchive.org")!
            var urls = [base.appending(path: "release-group/\(group.id.uuidString.lowercased())/")]
            var seen = Set<UUID>()
            for release in (group.releases ?? []) where seen.insert(release.id).inserted {
                urls.append(base.appending(path: "release/\(release.id.uuidString.lowercased())/"))
                if urls.count == 4 { break }
            }
            return urls
        }
        return []
    }

    private static func albumTitles(_ album: String) -> [String] {
        let separators = [" - ", " – ", " — ", ": "]
        guard let separator = separators.compactMap({ album.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return [album]
        }
        let main = String(album[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return main.isEmpty ? [album] : [album, main]
    }

    static func frontCover(in data: Data) throws -> URL? {
        let cover = try JSONDecoder().decode(Cover.self, from: data)
        for image in cover.images where image.front {
            guard let thumbnail = image.thumbnails["500"] ?? image.thumbnails["250"] ?? image.thumbnails["small"],
                  var components = URLComponents(url: thumbnail, resolvingAgainstBaseURL: false),
                  components.host?.lowercased() == "coverartarchive.org",
                  components.scheme == "http" || components.scheme == "https" else { continue }
            components.scheme = "https"
            return components.url
        }
        return nil
    }

    private static func request(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5"
        request.setValue("iSyncer/\(version) (com.jaz.isyncer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Catalogs can write a numeric exponent with superscripts while local tags use a caret.
    private static func catalogCredit(_ text: String) -> String {
        let superscripts = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        let pattern = #/\^([0-9]+)/#
        var credit = text
        for match in text.matches(of: pattern).reversed() {
            let digits = match.1.compactMap(\.wholeNumberValue)
            credit.replaceSubrange(match.range, with: String(digits.map { superscripts[$0] }))
        }
        return credit
    }
}
