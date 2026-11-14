import AppKit
import ClassicSync
import SwiftUI
import UniformTypeIdentifiers

extension Sequence {
    func only(where matches: (Element) -> Bool) -> Element? {
        var found: Element?
        for element in self where matches(element) {
            if found != nil { return nil }
            found = element
        }
        return found
    }
}

struct InboxEntry: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let tags: TagInfo

    var matchKey: [String] {
        Self.matchKey(tags.title, tags.album, tags.albumArtist.isEmpty ? tags.artist : tags.albumArtist)
    }

    static func matchKey(_ title: String, _ album: String, _ artist: String) -> [String] {
        [title, album, artist].map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    static func scan(_ sources: [URL]) -> [InboxEntry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var urls = Set<URL>()
        for source in sources {
            let url = source.standardizedFileURL
            if (try? url.resourceValues(forKeys: keys))?.isDirectory == true,
               let children = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                urls.formUnion(children.compactMap { $0 as? URL })
            } else { urls.insert(url) }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, TagReader.audioExtensions.contains(url.pathExtension.lowercased()),
                  var tags = TagReader.read(url: url, wantArtwork: true) else { return nil }
            if tags.artwork == nil, let image = ArtworkLoader.folderImage(in: url.deletingLastPathComponent()) {
                tags.artwork = try? Data(contentsOf: image)
            }
            return InboxEntry(url: url, tags: tags)
        }
    }
}

@MainActor
struct ImportInbox: View {
    @ObservedObject var library: LibraryStore
    @AppStorage("inboxSource") private var sourcePath = ""
    @State private var entries: [InboxEntry] = []
    @State private var selected = Set<URL>()
    @State private var replacements = Set<URL>()
    @State private var status = ""
    @State private var working = false

    var body: some View {
        let candidates = library.inboxMatchIndex()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Files or Folders…") { choose() }
                if !sourcePath.isEmpty {
                    Button("Scan Saved Folder") { scan([URL(fileURLWithPath: sourcePath)]) }
                        .help(sourcePath)
                }
            }
            Text("Drop audio files or a folder here to review tags and duplicates.")
                .foregroundStyle(.secondary)
            List(entries) { entry in
                let matches = library.importMatches(entry, among: candidates[entry.matchKey] ?? [])
                let replaceable = matches.count == 1 && library.isImportUpgrade(entry, over: matches[0])
                HStack(spacing: 10) {
                    Toggle("", isOn: membership($selected, entry.id)).labelsHidden()
                        .disabled(!matches.isEmpty && !replacements.contains(entry.id))
                    if let data = entry.tags.artwork, let cover = NSImage(data: data) {
                        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit).frame(width: 38, height: 38)
                    } else {
                        Image(systemName: "music.note").frame(width: 38, height: 38)
                    }
                    VStack(alignment: .leading) {
                        Text(entry.tags.title)
                        Text([entry.tags.artist, entry.tags.album, entry.tags.codec,
                              entry.tags.bitrate > 0 ? "\(entry.tags.bitrate) kbps" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if replaceable {
                        Toggle("Replace library copy", isOn: membership($replacements, entry.id))
                            .onChange(of: replacements.contains(entry.id)) {
                                if replacements.contains(entry.id) { selected.insert(entry.id) }
                                else { selected.remove(entry.id) }
                            }
                    } else if !matches.isEmpty {
                        Text(matches.count == 1 ? "In Library" : "Multiple matches").foregroundStyle(.secondary)
                    }
                }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Import Selected") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || library.libraryRoot == nil || library.isScanning || library.isScanningVideos)
            }
        }
        .padding(16)
        .frame(minWidth: 710, minHeight: 420)
        .disabled(working)
        .dropDestination(for: URL.self) { urls, _ in
            guard !working else { return false }
            scan(urls)
            return true
        }
    }

    private func membership(_ set: Binding<Set<URL>>, _ id: URL) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { value in
            if value { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }

    private func choose() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        if picker.runModal() == .OK {
            if picker.urls.count == 1, let url = picker.url, url.hasDirectoryPath { sourcePath = url.path }
            scan(picker.urls)
        }
    }

    private func scan(_ sources: [URL]) {
        working = true
        status = "Reading tags…"
        Task {
            entries = await Task.detached { InboxEntry.scan(sources) }.value
            let candidates = library.inboxMatchIndex()
            selected = Set(entries.filter { library.importMatches($0, among: candidates[$0.matchKey] ?? []).isEmpty }.map(\.id))
            replacements = []
            status = entries.isEmpty ? "No readable audio files found." : ""
            working = false
        }
    }

    private func apply() {
        var imported = Set<URL>()
        var failures: [String] = []
        for entry in entries where selected.contains(entry.id) {
            do {
                try library.importInboxEntry(entry, replace: replacements.contains(entry.id))
                imported.insert(entry.id)
            } catch { failures.append("\(entry.tags.title) · \(error.localizedDescription)") }
        }
        entries.removeAll { imported.contains($0.id) }
        selected.subtract(imported)
        replacements.subtract(imported)
        status = (["\(imported.count) imported"] + failures).joined(separator: "\n")
        if !imported.isEmpty { library.scan() }
    }
}

struct ListeningChange: Identifiable {
    enum Local {
        case audio(Track)
        case video(VideoItem, URL, VideoWatchHistory.State)
    }

    let local: Local
    let play: DevicePlayCount
    let position: Double

    var id: String {
        switch local {
        case .audio(let track): track.id
        case .video(let video, _, _): video.id
        }
    }

    var title: String {
        switch local {
        case .audio(let track): track.title
        case .video(let video, _, _): video.kind == .tv ? "\(video.show) · \(play.title)" : play.title
        }
    }

    var macState: ClassicListeningState {
        switch local {
        case .audio(let track):
            return .init(seconds: track.resumePosition ?? 0, played: track.finishedListening == true)
        case .video(_, _, let state):
            return .init(seconds: state.seconds, played: state.watched)
        }
    }

    var iPodState: ClassicListeningState { play.listeningState }

    var macPositionLabel: String { Self.label(macState) }
    var iPodPositionLabel: String { Self.label(iPodState) }

    private static func label(_ state: ClassicListeningState) -> String {
        state.played && state.milliseconds == 0 ? "Finished" : Format.duration(Double(state.milliseconds) / 1000)
    }

    var comparison: String {
        if case .audio(let track) = local, play.kind == .music {
            return "Mac: \(track.rating) stars · iPod: \(play.rating) stars"
        }
        return "Mac: \(macPositionLabel) · iPod: \(iPodPositionLabel)"
    }
}

@MainActor
struct ListeningImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let changes: [ListeningChange]
    let apply: ([ListeningChange]) -> Void
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iPod Ratings").font(.headline)
            if changes.isEmpty {
                ContentUnavailableView("No differences", systemImage: "ipod")
            } else {
                List(changes) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: {
                        if $0 { selected.insert(item.id) } else { selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.comparison).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button("Select All") { selected = Set(changes.map(\.id)) }.disabled(changes.isEmpty)
                Spacer()
                Button("Close") { dismiss() }
                Button("Use iPod Values") { apply(changes.filter { selected.contains($0.id) }); dismiss() }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }
}

@MainActor
struct PlaybackConflictSheet: View {
    let conflicts: [ListeningChange]
    let cancel: () -> Void
    let confirm: ([String: Bool]) -> Void
    @State private var choices: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Playback Progress").font(.headline)
            Text("Both devices have different progress for these items. Choose the position to keep on both.")
                .foregroundStyle(.secondary)
            List(conflicts) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).fontWeight(.medium)
                    Picker("Position for \(item.title)", selection: Binding<Bool?>(
                        get: { choices[item.id] }, set: { choices[item.id] = $0 }
                    )) {
                        Text("Choose…").tag(nil as Bool?)
                        Text("Mac · \(item.macPositionLabel)").tag(Optional(false))
                        Text("iPod · \(item.iPodPositionLabel)").tag(Optional(true))
                    }.labelsHidden()
                }.padding(.vertical, 3)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue", action: { confirm(choices) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(conflicts.contains { choices[$0.id] == nil })
            }
        }.padding(16).frame(width: 540, height: 410)
    }
}
