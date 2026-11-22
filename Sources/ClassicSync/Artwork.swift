import AudioToolbox
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Classic ArtworkDB record layout follows libgpod's db-itunes-parser.h and db-artwork-writer.c.
final class ArtworkWriter {
    private struct Format {
        let id: Int
        let width: Int
        let height: Int
        var size: Int { width * height * 2 }
    }

    private static let formats = [
        Format(id: 1061, width: 56, height: 56), Format(id: 1055, width: 128, height: 128),
        Format(id: 1068, width: 128, height: 128), Format(id: 1060, width: 320, height: 320)
    ]

    private struct Stream {
        let name: String
        let handle: FileHandle
        var offset = 0
    }

    private let directory: URL
    private let database: URL
    private let original: Data?
    private let header: Data
    private let sections: [Chunk]
    private let imageList: Chunk
    private(set) var artworkOwners: [Int: Data] = [:]
    private var artworkRecords: [Int: Chunk] = [:]
    private var nextID = 100
    private var streams: [Int: Stream] = [:]
    private var created: [URL] = []
    private var records: [Data] = []
    private var cached: [Data: Database.ArtworkLink] = [:]
    private var installed = false
    private var remainingBytes: Int64
    private(set) var skippedForSpace = false

    init(control: URL, reservedIDs: Set<Int>, remainingBytes: Int64) throws {
        self.remainingBytes = remainingBytes
        let directory = control.appending(path: "Artwork")
        self.directory = directory
        let database = directory.appending(path: "ArtworkDB")
        self.database = database
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw SyncError("The iPod artwork directory is invalid.")
            }
        }
        let original: Data?
        if fm.fileExists(atPath: database.path) {
            guard try database.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw SyncError("The iPod artwork database is invalid.")
            }
            original = try Data(contentsOf: database)
        } else { original = nil }
        self.original = original
        let data = original ?? Self.emptyDatabase()
        let root = try Chunk(data, at: 0, before: data.count, tag: "mhfd", minimum: 32)
        header = root.headerBytes(in: data)
        var offset = root.body
        var sections: [Chunk] = []
        var imageList: Chunk?
        var largest = max(99, reservedIDs.max() ?? 0, data.u32(28))
        for _ in 0..<data.u32(20) {
            let section = try Chunk(data, at: offset, before: root.end, tag: "mhsd", minimum: 16)
            sections.append(section)
            if data.u32(offset + 12) == 1 {
                let list = try Chunk(data, at: section.body, before: section.end, tag: "mhli", minimum: 12, isList: true)
                imageList = list
                var image = list.body
                for _ in 0..<data.u32(list.offset + 8) {
                    let record = try Chunk(data, at: image, before: section.end, tag: "mhii", minimum: 52)
                    let id = data.u32(image + 16)
                    largest = max(largest, id)
                    artworkOwners[id] = data.subdata(in: image + 20..<image + 28)
                    artworkRecords[id] = record
                    image = record.end
                }
                guard image == section.end else { throw SyncError("Unexpected records in ArtworkDB.") }
            }
            offset = section.end
        }
        guard let imageList, offset == root.end, root.end == data.count else {
            throw SyncError("Could not read the iPod artwork database.")
        }
        self.sections = sections
        self.imageList = imageList
        nextID = largest + 1
    }

    func matches(_ imageData: Data, artworkID: Int) -> Bool {
        guard let original, let record = artworkRecords[artworkID],
              let format = Self.formats.last, let image = Self.thumbnail(imageData),
              let expected = try? Self.encode(image, format: format) else { return false }
        return thumbnailBytes(original, record: record, format: format) == expected
    }

    func previewImage(artworkID: Int) -> Data? {
        guard let original, let record = artworkRecords[artworkID], let format = Self.formats.first,
              let raw = thumbnailBytes(original, record: record, format: format) else { return nil }
        return Self.previewImage(raw, format: format)
    }

    private static func previewImage(_ raw: Data, format: Format) -> Data? {
        var rgb = Data(capacity: format.width * format.height * 3)
        for index in stride(from: 0, to: raw.count, by: 2) {
            let value = raw.u16(index)
            rgb.append(UInt8(((value >> 11) & 31) * 255 / 31))
            rgb.append(UInt8(((value >> 5) & 63) * 255 / 63))
            rgb.append(UInt8((value & 31) * 255 / 31))
        }
        guard let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(width: format.width, height: format.height, bitsPerComponent: 8,
                                  bitsPerPixel: 24, bytesPerRow: format.width * 3,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    private func thumbnailBytes(_ original: Data, record: Chunk, format: Format) -> Data? {
        var offset = record.body
        while offset < record.end {
            guard let object = try? Chunk(original, at: offset, before: record.end, tag: "mhod", minimum: 24) else { return nil }
            offset = object.end
            guard let info = try? Chunk(original, at: object.body, before: object.end, tag: "mhni", minimum: 36),
                  original.u32(info.offset + 16) == format.id,
                  original.u32(info.offset + 24) == format.size,
                  let location = try? Chunk(original, at: info.body, before: info.end, tag: "mhod", minimum: 24),
                  location.end - location.offset >= 36 else { continue }
            let start = location.offset + 36
            let length = original.u32(location.offset + 24)
            guard length <= location.end - start,
                  let name = String(data: original[start..<(start + length)], encoding: .utf16LittleEndian),
                  name.range(of: #"^:F\d+_\d+\.ithmb$"#, options: .regularExpression) != nil,
                  let file = try? FileHandle(forReadingFrom: directory.appending(path: String(name.dropFirst()))) else { return nil }
            defer { try? file.close() }
            do {
                try file.seek(toOffset: UInt64(original.u32(info.offset + 20)))
                guard let bytes = try file.read(upToCount: format.size), bytes.count == format.size else { return nil }
                return bytes
            } catch { return nil }
        }
        return nil
    }

    static func previewImage(_ data: Data) -> Data? {
        guard let image = Self.thumbnail(data), let format = Self.formats.first,
              let raw = try? Self.encode(image, format: format) else { return nil }
        return Self.previewImage(raw, format: format)
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640
        ] as CFDictionary)
    }

    static func sourceArtwork(for song: Song) -> Data? {
        if let selected = song.musicArtwork { return selected }
        if song.reviewsMusicArtwork {
            let source = song.audioSource?.url ?? song.url
            return EmbeddedArtwork.data(at: source) ?? MediaArtwork.externalData(at: source)
        }
        let spoken = song.classification == .podcast || song.classification == .audiobook
        if let source = song.audioSource?.url {
            return MediaArtwork.externalData(at: song.url) ?? MediaArtwork.externalData(at: source) ?? EmbeddedArtwork.data(at: source)
        }
        return song.videoMetadata?.artworkData
            ?? (spoken ? MediaArtwork.externalData(at: song.url) : nil)
            ?? EmbeddedArtwork.data(at: song.url)
    }

    func add(song: Song, persistentID: Data) throws -> Database.ArtworkLink? {
        guard let imageData = Self.sourceArtwork(for: song) else { return nil }
        var artworkHash = SHA256()
        artworkHash.update(data: imageData)
        if song.classification == .podcast { artworkHash.update(data: persistentID) }
        let digest = Data(artworkHash.finalize())
        if let existing = cached[digest] {
            return existing
        }
        guard let image = Self.thumbnail(imageData), nextID < Int(UInt32.max) else { return nil }

        let bytesNeeded = Int64(Self.formats.reduce(4096) { $0 + $1.size })
        guard remainingBytes >= bytesNeeded else {
            skippedForSpace = true
            return nil
        }
        remainingBytes -= bytesNeeded
        let thumbnails = try Self.formats.map { format -> Data in
            let bytes = try Self.encode(image, format: format)
            let stream = try append(bytes, format: format)
            let name = Data((":" + stream.name).utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
            let padding = (4 - name.count % 4) % 4
            var location = Data.record("mhod", header: 36, children: [name, Data(count: padding)])
            location.put(24, at: 4)
            location[12] = 3
            location[15] = UInt8(padding)
            location.put(name.count, at: 24)
            location[28] = 2

            var info = Data.record("mhni", header: 76, children: [location])
            info.put(1, at: 12)
            info.put(format.id, at: 16)
            info.put(stream.offset, at: 20)
            info.put(format.size, at: 24)
            info.put(format.height | (format.width << 16), at: 32)
            var object = Data.record("mhod", header: 24, children: [info])
            object[12] = 2
            return object
        }
        var record = Data.record("mhii", header: 152, children: thumbnails)
        record.put(thumbnails.count, at: 12)
        record.put(nextID, at: 16)
        record.replaceSubrange(20..<28, with: persistentID)
        record.put(imageData.count + 1, at: 48)
        records.append(record)
        let link = Database.ArtworkLink(id: nextID, size: imageData.count)
        cached[digest] = link
        nextID += 1
        return link
    }

    func install(backup: URL) throws {
        guard !records.isEmpty else { return }
        for stream in streams.values { try stream.handle.synchronize(); try stream.handle.close() }
        streams.removeAll()
        let base = original ?? Self.emptyDatabase()
        let live = try? Data(contentsOf: database)
        guard live == original else { throw SyncError("The iPod artwork database changed during sync.") }
        if let original { try original.write(to: backup, options: .atomic) }
        var output = header
        for section in sections {
            if base.u32(section.offset + 12) == 1 {
                var data = section.bytes(in: base)
                let countOffset = imageList.offset - section.offset + 8
                data.put(data.u32(countOffset) + records.count, at: countOffset)
                for record in records { data.append(record) }
                data.put(data.count, at: 8)
                output.append(data)
            } else {
                output.append(section.bytes(in: base))
            }
        }
        output.put(output.count, at: 8)
        output.put(nextID, at: 28)
        try output.write(to: database, options: .atomic)
        installed = true
    }

    deinit {
        for stream in streams.values { try? stream.handle.close() }
        // Once installed, leave the append-only index and its thumbnails together.
        // The old iTunesDB can still reference all of its original artwork.
        guard !installed else { return }
        for url in created { try? FileManager.default.removeItem(at: url) }
    }

    private func append(_ bytes: Data, format: Format) throws -> Stream {
        let fm = FileManager.default
        var stream = streams[format.id]
        if let existing = stream, existing.offset + bytes.count >= 256_000_000 {
            try existing.handle.synchronize()
            try existing.handle.close()
            streams.removeValue(forKey: format.id)
            stream = nil
        }
        if stream == nil {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            var index = 1
            var url = directory.appending(path: "F\(format.id)_\(index).ithmb")
            while fm.fileExists(atPath: url.path) {
                index += 1
                url = directory.appending(path: "F\(format.id)_\(index).ithmb")
            }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw SyncError("Could not create iPod artwork thumbnails.")
            }
            created.append(url)
            stream = Stream(name: url.lastPathComponent, handle: try FileHandle(forWritingTo: url))
        }
        guard var stream else { throw SyncError("Could not open the iPod artwork thumbnails.") }
        let location = stream
        try stream.handle.write(contentsOf: bytes)
        stream.offset += bytes.count
        streams[format.id] = stream
        return location
    }

    private static func encode(_ image: CGImage, format: Format) throws -> Data {
        var rgba = [UInt8](repeating: 0, count: format.width * format.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: format.width, height: format.height,
                                          bitsPerComponent: 8, bytesPerRow: format.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
            let side = CGFloat(min(image.width, image.height))
            let scale = bounds.width / side
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                           width: size.width, height: size.height))
            return true
        }
        guard drawn else { throw SyncError("Could not render iPod artwork.") }
        var output = Data(count: format.size)
        output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for pixel in 0..<(rgba.count / 4) {
                let offset = pixel * 4
                let r = UInt16(rgba[offset]) >> 3
                let g = UInt16(rgba[offset + 1]) >> 2
                let b = UInt16(rgba[offset + 2]) >> 3
                let value = (r << 11) | (g << 5) | b
                bytes[pixel * 2] = UInt8(truncatingIfNeeded: value)
                bytes[pixel * 2 + 1] = UInt8(value >> 8)
            }
        }
        return output
    }

    private static func emptyDatabase() -> Data {
        var images = Data.record("mhli", header: 92)
        images.put(0, at: 8)
        var albums = Data.record("mhla", header: 92)
        albums.put(0, at: 8)
        let formats = formats.map { format in
            var record = Data.record("mhif", header: 124)
            record.put(format.id, at: 16)
            record.put(format.size, at: 20)
            return record
        }
        var files = Data.record("mhlf", header: 92, children: formats)
        files.put(formats.count, at: 8)
        let sections = [images, albums, files].enumerated().map { index, list in
            var section = Data.record("mhsd", header: 96, children: [list])
            section.put(index + 1, at: 12)
            return section
        }
        var database = Data.record("mhfd", header: 132, children: sections)
        database.put(2, at: 16)
        database.put(sections.count, at: 20)
        database.put(99, at: 28)
        database[48] = 2
        return database
    }
}

public enum EmbeddedArtwork {
    public static func thumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        guard let data = data(at: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary)
    }

    static func data(at url: URL) -> Data? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var result: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout.size(ofValue: result))
        guard AudioFileGetProperty(file, kAudioFilePropertyAlbumArtwork, &size, &result) == noErr,
              let result else { return nil }
        return result.takeRetainedValue() as Data
    }
}

public enum MediaArtwork {
    public static func externalData(at url: URL) -> Data? {
        let folder = url.deletingLastPathComponent()
        let covers = ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg"].map { folder.appending(path: $0) }
        for candidate in [url.appendingPathExtension("cover")] + covers {
            if let data = imageData(at: candidate) { return data }
        }
        return nil
    }

    static func imageData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...8_388_608).contains(size),
              let data = try? Data(contentsOf: url), CGImageSourceCreateWithData(data as CFData, nil) != nil else { return nil }
        return data
    }
}
