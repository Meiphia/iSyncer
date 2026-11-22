import Foundation

/// Prepared iPod media. The default layout preserves caches from earlier builds.
struct ConversionCache: Equatable, Sendable {
    private static let folderName = "Cache"
    private static let markerName = ".isyncer-conversion-cache"

    let defaultFolder: URL
    let parent: URL?

    var folder: URL { parent?.appendingPathComponent(Self.folderName, isDirectory: true) ?? defaultFolder }
    var audio: URL { folder.appendingPathComponent("Classic Audio", isDirectory: true) }
    var video: URL { folder.appendingPathComponent("Classic Videos", isDirectory: true) }
    static func defaultVideo(in folder: URL) -> URL { Self(defaultFolder: folder, parent: nil).video }

    static func isManagedFolder(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare(folderName) == .orderedSame &&
            FileManager.default.fileExists(atPath: url.appendingPathComponent(markerName).path)
    }

    func checkAvailable() throws {
        guard parent == nil || Self.isManagedFolder(folder) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The conversion cache is unavailable. Reconnect its drive or choose a cache location in Settings."
            ])
        }
        try checkCacheDirectories()
    }

    func prepare() throws {
        guard let parent else { try checkCacheDirectories(); return }
        let fm = FileManager.default
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        let standard = Self(defaultFolder: defaultFolder, parent: nil)
        var ancestor = parent
        while ancestor.path != "/" {
            if Self.isManagedFolder(ancestor) || ancestor.path == standard.audio.path || ancestor.path == standard.video.path {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                    NSLocalizedDescriptionKey: "Choose a folder outside an existing conversion cache."
                ])
            }
            ancestor.deleteLastPathComponent()
        }
        if fm.fileExists(atPath: folder.path) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let managedOrEmpty = try Self.isManagedFolder(folder) ||
                fm.contentsOfDirectory(atPath: folder.path).allSatisfy { $0 == ".DS_Store" }
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  managedOrEmpty else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSLocalizedDescriptionKey: "This location already has a Cache folder with other files. Choose another location."
                ])
            }
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try checkCacheDirectories()
        try Data().write(to: folder.appendingPathComponent(Self.markerName), options: .atomic)
    }

    private func checkCacheDirectories() throws {
        for directory in (parent == nil ? [] : [folder]) + [audio, video] {
            if let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory != true || values.isSymbolicLink == true {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSLocalizedDescriptionKey: "The conversion cache must use regular folders."
                ])
            }
        }
    }

    var hasFiles: Bool { [audio, video].contains { (try? files(in: $0).isEmpty) == false } }

    /// Copy all entries before removing any originals so an interrupted copy can be retried.
    func moveFiles(to destination: Self) throws -> Int {
        let fm = FileManager.default
        try checkAvailable()
        try destination.checkAvailable()
        var copied: [URL] = []
        var kept = 0
        for (from, to) in [(audio, destination.audio), (video, destination.video)] {
            guard from.resolvingSymlinksInPath().path != to.resolvingSymlinksInPath().path else { continue }
            let entries = try files(in: from)
            guard !entries.isEmpty else { continue }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for entry in entries {
                let target = to.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    if fm.contentsEqual(atPath: entry.path, andPath: target.path) { copied.append(entry) }
                    else { kept += 1 }
                    continue
                }
                let temporary = to.appendingPathComponent(".\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: entry, to: temporary)
                try fm.moveItem(at: temporary, to: target)
                copied.append(entry)
            }
        }
        for original in copied {
            do { try fm.removeItem(at: original) }
            catch { kept += 1 }
        }
        return kept
    }

    private func files(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                  options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        return entries.filter {
            guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }
}
