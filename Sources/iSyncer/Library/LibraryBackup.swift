import AppKit
import ClassicSync
import Foundation
import UniformTypeIdentifiers

/// A portable metadata archive with an explicit list of files and preferences.
struct LibraryBackup: Codable, Sendable {
    let version: Int
    let created: Date
    let files: [String: Data]
    let preferences: [String: Data]

    static let directories = ["Collection", "Video Metadata"]
    static let preferenceKeys = ["classicSyncSettings", "podcastSubscriptions", "videoWatchHistory",
                                 "iPodPlaybackBaselines", "excludedClassicPlaylists", "managedClassicPlaylists"]

    static func allowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }) else { return false }
        return path == "library.json" || (parts.count > 1 && directories.contains(String(parts[0])))
    }

    func validate() throws {
        guard version == 1, let library = files["library.json"],
              files.keys.allSatisfy(Self.allowed), preferences.keys.allSatisfy(Self.preferenceKeys.contains) else {
            throw ShellError(message: "This file is not a supported iSyncer library backup.")
        }
        try LibraryStore.validateBackup(library)
        for data in preferences.values {
            guard let preference = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  preference["value"] != nil else { throw ShellError(message: "A backup preference is invalid.") }
        }
        if let collection = files["Collection/collection.json"] {
            let saved = try JSONDecoder().decode(LibraryCollection.Saved.self, from: collection)
            for gallery in saved.galleries.values {
                guard gallery.pictures.allSatisfy({ picture in
                    picture.file == picture.id.uuidString + ".png" && files["Collection/" + picture.file] != nil
                }) else { throw ShellError(message: "The artwork gallery in this backup is incomplete.") }
            }
        }
        for (key, data) in preferences {
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            switch key {
            case "classicSyncSettings":
                guard let encoded = plist?["value"] as? Data else { throw ShellError(message: "Invalid sync settings.") }
                _ = try JSONDecoder().decode([String: ClassicSyncSettings].self, from: encoded)
            case "podcastSubscriptions":
                guard let encoded = plist?["value"] as? Data else { throw ShellError(message: "Invalid podcast subscriptions.") }
                _ = try JSONDecoder().decode([PodcastSubscriptions.Subscription].self, from: encoded)
            case "videoWatchHistory":
                guard let encoded = plist?["value"] as? Data else { throw ShellError(message: "Invalid video history.") }
                _ = try JSONDecoder().decode([String: VideoWatchHistory.State].self, from: encoded)
            case "iPodPlaybackBaselines":
                guard let encoded = plist?["value"] as? Data else { throw ShellError(message: "Invalid iPod playback history.") }
                _ = try JSONDecoder().decode([String: [String: ClassicListeningState]].self, from: encoded)
            default:
                guard plist?["value"] is [String] else { throw ShellError(message: "Invalid playlist selection.") }
            }
        }
    }

    @MainActor static func snapshot() throws -> Self {
        PlayerEngine.shared.saveCurrentListening()
        LibraryStore.shared.saveNowBlocking()
        let root = LibraryStore.supportFolder
        let fm = FileManager.default
        var files = ["library.json": try Data(contentsOf: root.appending(path: "library.json"))]
        for name in directories {
            let folder = root.appending(path: name)
            guard fm.fileExists(atPath: folder.path) else { continue }
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ShellError(message: "A library backup folder contains a symbolic link.")
            }
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                                                options: [.skipsHiddenFiles]) else {
                throw ShellError(message: "Couldn’t read " + name)
            }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw ShellError(message: "A library backup folder contains a symbolic link.") }
                if values.isRegularFile == true, let relative = Scanner.relativePath(of: url, rootPath: root.path) {
                    files[relative] = try Data(contentsOf: url)
                }
            }
        }
        var preferences: [String: Data] = [:]
        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                preferences[key] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
            }
        }
        return Self(version: 1, created: Date(), files: files, preferences: preferences)
    }

    @MainActor func restore() throws {
        try validate()
        let root = LibraryStore.supportFolder
        let fm = FileManager.default
        let staging = root.appending(path: ".restore-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var keepRecovery = false
        defer { if !keepRecovery { try? fm.removeItem(at: staging) } }
        let prepared = staging.appending(path: "Prepared")
        let previous = staging.appending(path: "Previous")
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        for (path, data) in files {
            let destination = prepared.appending(path: path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        let names = ["library.json"] + Self.directories
        var moved = [String]()
        var installed = [String]()
        LibraryStore.shared.saveNowBlocking()
        do {
            for name in names {
                let live = root.appending(path: name)
                if fm.fileExists(atPath: live.path) {
                    try fm.moveItem(at: live, to: previous.appending(path: name))
                    moved.append(name)
                }
                let replacement = prepared.appending(path: name)
                if fm.fileExists(atPath: replacement.path) {
                    try fm.moveItem(at: replacement, to: live)
                    installed.append(name)
                }
            }
        } catch {
            var rollbackErrors = [String]()
            for name in installed {
                do { try fm.removeItem(at: root.appending(path: name)) }
                catch { rollbackErrors.append(name) }
            }
            for name in moved {
                do { try fm.moveItem(at: previous.appending(path: name), to: root.appending(path: name)) }
                catch { rollbackErrors.append(name) }
            }
            if !rollbackErrors.isEmpty {
                // Keep the original files available if a disk error also prevents rollback.
                keepRecovery = true
                throw ShellError(message: "Restore failed. Original files are available in " + previous.path)
            }
            throw error
        }
        for key in Self.preferenceKeys {
            if let data = preferences[key],
               let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                UserDefaults.standard.set(plist["value"], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        LibraryStore.shared.load()
        LibraryCollection.shared.reload()
        DeviceManager.shared.reloadSettings()
        PodcastSubscriptions.shared.reload()
        VideoWatchHistory.shared.reload()
    }
}

@MainActor
final class LibraryBackupController: ObservableObject {
    static let shared = LibraryBackupController()
    @Published private(set) var busy = false

    private var available: Bool {
        let library = LibraryStore.shared
        return !busy && !DeviceManager.shared.busy && !library.isScanning && !library.isScanningVideos &&
            !PodcastSubscriptions.shared.checking && !PodcastSubscriptions.shared.downloading && !LoudnessAnalyzer.shared.running
    }

    func export() {
        guard available else { message("Wait for the current library operation to finish."); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "iSyncer Library.isyncerbackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "isyncerbackup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try LibraryBackup.snapshot()
            busy = true
            Task {
                defer { busy = false }
                do {
                    try await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                    }.value
                    message("Library backup saved. Store your music and video files separately.")
                } catch { message(error.localizedDescription) }
            }
        } catch { message(error.localizedDescription) }
    }

    func restore() {
        guard available else { message("Wait for the current library operation to finish."); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "isyncerbackup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "Restore Library Backup?"
        confirmation.informativeText = "Replaces the current library index, playlists, history, gallery, and sync settings. A backup of your current setup will be saved first."
        confirmation.addButton(withTitle: "Cancel")
        confirmation.addButton(withTitle: "Restore")
        guard confirmation.runModal() == .alertSecondButtonReturn, available else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let archive = try await Task.detached(priority: .utility) {
                    try JSONDecoder().decode(LibraryBackup.self, from: Data(contentsOf: url))
                }.value
                guard !DeviceManager.shared.busy, !LibraryStore.shared.isScanning, !LibraryStore.shared.isScanningVideos,
                      !PodcastSubscriptions.shared.checking, !PodcastSubscriptions.shared.downloading else {
                    throw ShellError(message: "A library operation started. Restore again after it finishes.")
                }
                try archive.validate()
                let current = try LibraryBackup.snapshot()
                let backupURL = LibraryStore.supportFolder.appending(path: "Before Restore-" + UUID().uuidString + ".isyncerbackup")
                try JSONEncoder().encode(current).write(to: backupURL, options: .atomic)
                PlayerEngine.shared.stop()
                try archive.restore()
                if !LibraryStore.shared.libraryFolders.isEmpty {
                    LibraryStore.shared.scanVideos()
                }
                message("Library restored. Your previous setup was saved in " + backupURL.path +
                        ". Use File → Relink Media Folder if the media is in a different location.")
            } catch { message(error.localizedDescription) }
        }
    }

    func exportPlaylists() {
        guard available, let root = LibraryStore.shared.libraryRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let directory = destination.appending(path: "iSyncer Playlists-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for playlist in LibraryStore.shared.playlists {
                let paths = playlist.trackIDs.map { root.appendingLibraryPath($0).absoluteString }
                let text = (["#EXTM3U"] + paths).joined(separator: "\n") + "\n"
                let filename = PathRules.sanitize(playlist.name) + "-" + playlist.id.uuidString + ".m3u8"
                try text.write(to: directory.appending(path: filename), atomically: true, encoding: .utf8)
            }
            message("Playlists exported to " + directory.path)
        } catch { message(error.localizedDescription) }
    }

    private func message(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "iSyncer Library"
        alert.informativeText = text
        alert.runModal()
    }
}
