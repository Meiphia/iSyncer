import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Get Info window: Summary, Info (editable tags), Options and Artwork, for one song or
/// several at once. With several songs, a field shows a value only when all songs share it;
/// only the fields you change are written.
@MainActor
final class GetInfoController: NSObject, NSWindowDelegate {
    static let shared = GetInfoController()
    private var window: NSWindow?

    func show(ids: [String]) {
        let ids = ids.filter { LibraryStore.shared.track($0) != nil }
        guard !ids.isEmpty else { return }
        window?.close()
        let model = GetInfoModel(ids: ids)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.delegate = self
        w.contentView = NSHostingView(rootView: GetInfoView(model: model) { [weak w] in w?.close() })
        model.onTitle = { [weak w] title in w?.title = title }
        model.onTitle?(model.windowTitle)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { window = nil }
    }
}

@MainActor
final class GetInfoModel: ObservableObject {
    enum Field: String, CaseIterable {
        case title, artist, albumArtist, album, composer, grouping, genre, year
        case track, trackTotal, disc, discTotal, bpm, comment
    }

    @Published private(set) var ids: [String]
    @Published var values: [Field: String] = [:]
    @Published private(set) var original: [Field: String] = [:]
    @Published var compilation: Bool?        // nil = mixed
    @Published private(set) var originalCompilation: Bool?
    @Published var rating: Int?
    @Published private(set) var originalRating: Int?
    @Published var artwork: NSImage?
    @Published var newArtwork: URL?
    @Published var removeArtwork = false
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published var error: String?
    @Published private(set) var progress = ""
    var onTitle: ((String) -> Void)?

    private var library: LibraryStore { LibraryStore.shared }

    init(ids: [String]) {
        self.ids = ids
        load()
    }

    var isMulti: Bool { ids.count > 1 }
    var tracks: [Track] { ids.compactMap { library.track($0) } }
    var first: Track? { library.track(ids[0]) }

    var windowTitle: String {
        if isMulti { return "Multiple Song Information" }
        return first?.title ?? "Song Information"
    }

    var editable: Bool {
        tracks.allSatisfy { t in library.url(for: t).map(TagWriter.canEdit) ?? false }
    }

    var hasChanges: Bool {
        Field.allCases.contains { (values[$0] ?? "") != (original[$0] ?? "") }
            || compilation != originalCompilation || rating != originalRating
            || newArtwork != nil || removeArtwork
    }

    func binding(_ f: Field) -> Binding<String> {
        Binding(get: { self.values[f] ?? "" }, set: { self.values[f] = $0 })
    }

    /// Mixed fields are blank with a "Mixed" placeholder.
    func isMixed(_ f: Field) -> Bool { isMulti && original[f] == nil }

    // MARK: Loading

    private func load() {
        loading = true
        let urls = tracks.compactMap { library.url(for: $0) }
        let ts = tracks
        let multi = isMulti
        Task {
            let infos: [TagInfo] = await Task.detached(priority: .userInitiated) {
                urls.prefix(500).enumerated().map { i, url in
                    TagReader.read(url: url, wantArtwork: !multi || i == 0) ?? TagInfo()
                }
            }.value
            self.apply(infos: infos, tracks: ts)
        }
    }

    private func apply(infos: [TagInfo], tracks ts: [Track]) {
        func common<T: Equatable>(_ get: (TagInfo) -> T) -> T? {
            guard let f = infos.first else { return nil }
            let v = get(f)
            return infos.allSatisfy { get($0) == v } ? v : nil
        }
        func num(_ v: Int?) -> String? { v.map { $0 > 0 ? String($0) : "" } }
        var o: [Field: String] = [:]
        o[.title] = common { $0.title }
        o[.artist] = common { $0.artist }
        o[.albumArtist] = common { $0.albumArtist }
        o[.album] = common { $0.album }
        o[.composer] = common { $0.composer }
        o[.grouping] = common { $0.grouping }
        o[.genre] = common { $0.genre }
        o[.year] = num(common { $0.year })
        o[.track] = num(common { $0.track })
        o[.trackTotal] = num(common { $0.trackTotal })
        o[.disc] = num(common { $0.disc })
        o[.discTotal] = num(common { $0.discTotal })
        o[.bpm] = num(common { $0.bpm })
        o[.comment] = common { $0.comment }
        original = o
        values = o
        originalCompilation = common { $0.compilation }
        compilation = originalCompilation
        let ratings = Set(ts.map(\.rating))
        originalRating = ratings.count == 1 ? ratings.first : nil
        rating = originalRating
        if let data = infos.first?.artwork, let img = NSImage(data: data) {
            artwork = img
        } else if let t = ts.first {
            Task { self.artwork = await ArtworkLoader.shared.image(for: t) }
        }
        newArtwork = nil
        removeArtwork = false
        loading = false
        onTitle?(windowTitle)
    }

    // MARK: Previous / Next (single song)

    func step(_ delta: Int, in order: [String]) async {
        guard !isMulti, let i = order.firstIndex(of: ids[0]) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        if hasChanges { guard await save() else { return } }
        ids = [order[j]]
        load()
    }

    // MARK: Saving

    func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a JPEG or PNG image for the artwork."
        if panel.runModal() == .OK, let url = panel.url {
            setArtwork(url)
        }
    }

    func setArtwork(_ url: URL) {
        newArtwork = url
        removeArtwork = false
        artwork = NSImage(contentsOf: url)
    }

    func clearArtwork() {
        newArtwork = nil
        removeArtwork = true
        artwork = nil
    }

    func makeEdit() -> TagEdit {
        var e = TagEdit()
        func changed(_ f: Field) -> String? {
            let v = (values[f] ?? "").trimmingCharacters(in: .whitespaces)
            let o = original[f] ?? ""
            if isMixed(f) && v.isEmpty { return nil }
            return v == o ? nil : v
        }
        func int(_ f: Field) -> Int? { changed(f).map { Int($0) ?? 0 } }
        e.title = isMulti ? nil : changed(.title)
        e.artist = changed(.artist)
        e.albumArtist = changed(.albumArtist)
        e.album = changed(.album)
        e.composer = changed(.composer)
        e.grouping = changed(.grouping)
        e.genre = changed(.genre)
        e.comment = changed(.comment)
        e.year = int(.year)
        e.track = isMulti ? nil : int(.track)
        e.trackTotal = int(.trackTotal)
        e.disc = int(.disc)
        e.discTotal = int(.discTotal)
        e.bpm = int(.bpm)
        if compilation != originalCompilation { e.compilation = compilation }
        e.artwork = newArtwork
        e.removeArtwork = removeArtwork
        return e
    }

    /// Writes the changes; returns false (and sets `error`) if any file failed.
    @discardableResult
    func save() async -> Bool {
        let ts = tracks
        if let r = rating, r != originalRating { library.setRating(ts.map(\.id), r) }
        let edit = makeEdit()
        guard !edit.isEmpty else { originalRating = rating; return true }
        saving = true
        defer { saving = false }
        var failures: [String] = []
        let jobs = ts.compactMap { t in library.url(for: t).map { (t.title, $0) } }
        progress = "0 of \(jobs.count)"
        var done = 0
        // A few files at a time: each write is a separate ffmpeg run.
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            func addJob() {
                guard next < jobs.count else { return }
                let (title, url) = jobs[next]
                next += 1
                group.addTask {
                    do { try await TagWriter.write(edit, to: url); return nil }
                    catch { return "\(title): \(error.localizedDescription)" }
                }
            }
            for _ in 0..<4 { addJob() }
            for await failure in group {
                if let failure { failures.append(failure) }
                done += 1
                progress = "\(done) of \(jobs.count)"
                addJob()
            }
        }
        progress = ""
        for t in ts { ArtworkLoader.shared.forget(t) }
        await library.refresh(ts.map(\.id))
        if failures.isEmpty {
            error = nil
            original = values
            originalCompilation = compilation
            originalRating = rating
            newArtwork = nil
            removeArtwork = false
            return true
        }
        error = failures.prefix(4).joined(separator: "\n") + (failures.count > 4 ? "\n…and \(failures.count - 4) more" : "")
        return false
    }
}

@MainActor
struct GetInfoView: View {
    @ObservedObject var model: GetInfoModel
    let close: () -> Void
    @State private var tab = "Info"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Summary").tag("Summary")
                Text("Info").tag("Info")
                Text("Options").tag("Options")
                Text("Artwork").tag("Artwork")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Group {
                if model.loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch tab {
                    case "Summary": summary
                    case "Options": options
                    case "Artwork": artworkTab
                    default: info
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 18)

            if let err = model.error {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 4)
            }
            footer
        }
        .frame(width: 520, height: 470)
        .preferredColorScheme(.light)
    }

    // MARK: Tabs

    private var summary: some View {
        let ts = model.tracks
        return HStack(alignment: .top, spacing: 16) {
            artworkBox(size: 120)
            VStack(alignment: .leading, spacing: 4) {
                if let t = model.first, !model.isMulti {
                    Text(t.title).font(.system(size: 14, weight: .semibold))
                    Text(t.artist).foregroundStyle(.secondary)
                    Text(t.album).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    row("Kind", t.kind)
                    row("Duration", Format.duration(t.duration))
                    row("Size", Format.bytes(t.size))
                    row("Bit Rate", t.bitrate > 0 ? "\(t.bitrate) kbps" : "—")
                    row("Sample Rate", t.sampleRate > 0 ? String(format: "%.1f kHz", Double(t.sampleRate) / 1000) : "—")
                    row("Date Added", date(t.dateAdded))
                    row("Modified", date(t.modified))
                    row("Plays", t.playCount > 0 ? "\(t.playCount), last \(date(t.lastPlayed))" : "Never")
                    row("Where", t.id)
                } else {
                    Text("\(ts.count) songs").font(.system(size: 14, weight: .semibold))
                    Divider().padding(.vertical, 4)
                    row("Total Time", Format.duration(ts.reduce(0) { $0 + $1.duration }))
                    row("Total Size", Format.bytes(ts.reduce(Int64(0)) { $0 + $1.size }))
                    row("Plays", "\(ts.reduce(0) { $0 + $1.playCount })")
                }
                if !model.editable {
                    Text("Some of these files can't be edited (only MP3, AAC/ALAC, FLAC, Ogg and Opus).")
                        .font(.system(size: 10)).foregroundStyle(.orange).padding(.top, 6)
                }
            }
            .font(.system(size: 11))
        }
    }

    private var info: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            if !model.isMulti { field("Name", .title, span: true) }
            field("Artist", .artist, span: true)
            field("Album Artist", .albumArtist, span: true)
            field("Album", .album, span: true)
            field("Composer", .composer, span: true)
            field("Grouping", .grouping, span: true)
            GridRow {
                label("Genre")
                genreField
                label("Year")
                textField(.year).frame(width: 60)
            }
            GridRow {
                label("Track")
                HStack(spacing: 4) {
                    if model.isMulti {
                        Text("—").foregroundStyle(.secondary).frame(width: 40)
                    } else {
                        textField(.track).frame(width: 40)
                    }
                    Text("of")
                    textField(.trackTotal).frame(width: 40)
                    Spacer()
                }
                label("BPM")
                textField(.bpm).frame(width: 60)
            }
            GridRow {
                label("Disc")
                HStack(spacing: 4) {
                    textField(.disc).frame(width: 40)
                    Text("of")
                    textField(.discTotal).frame(width: 40)
                    Spacer()
                    Toggle("Part of a compilation", isOn: Binding(
                        get: { model.compilation ?? false },
                        set: { model.compilation = $0 }))
                }
                .gridCellColumns(3)
            }
            GridRow(alignment: .top) {
                label("Comments")
                TextEditor(text: model.binding(.comment))
                    .font(.system(size: 11))
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4)))
                    .gridCellColumns(3)
            }
        }
        .font(.system(size: 11))
        .disabled(!model.editable || model.saving)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("My Rating").frame(width: 80, alignment: .trailing)
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: (model.rating ?? 0) >= star ? "star.fill" : "star")
                            .foregroundStyle(model.rating == nil ? Color.secondary : Color.primary)
                            .onTapGesture { model.rating = model.rating == star ? 0 : star }
                    }
                }
                if model.rating == nil { Text("Mixed").foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Text("Sync").frame(width: 80, alignment: .trailing)
                let allChecked = model.ids.allSatisfy { LibraryStore.shared.isChecked($0) }
                Toggle("Checked (included when syncing)", isOn: Binding(
                    get: { allChecked },
                    set: { LibraryStore.shared.setChecked(model.ids, $0); model.objectWillChange.send() }))
            }
            HStack(spacing: 8) {
                Text("Play Count").frame(width: 80, alignment: .trailing)
                let plays = model.tracks.reduce(0) { $0 + $1.playCount }
                Text("\(plays)")
                Button("Reset") {
                    LibraryStore.shared.resetPlayCount(model.ids)
                    model.objectWillChange.send()
                }
                .disabled(plays == 0)
            }
        }
        .font(.system(size: 11))
        .padding(.top, 8)
    }

    private var artworkTab: some View {
        VStack(spacing: 12) {
            artworkBox(size: 240)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard let p = providers.first else { return false }
                    let m = model
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in m.setArtwork(url) }
                    }
                    return true
                }
            HStack {
                Button("Add…") { model.chooseArtwork() }
                Button("Delete") { model.clearArtwork() }.disabled(model.artwork == nil)
            }
            Text(model.isMulti ? "The new artwork goes into every selected song." : "Drop an image here, or choose one.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .disabled(!model.editable || model.saving)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if !model.isMulti {
                Button("Previous") { Task { await model.step(-1, in: BrowserModelLink.order) } }
                Button("Next") { Task { await model.step(1, in: BrowserModelLink.order) } }
            }
            if model.saving {
                ProgressView().controlSize(.small).padding(.leading, 6)
                if !model.progress.isEmpty { Text("Saving \(model.progress)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            Button("OK") {
                Task {
                    if await model.save() { close() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.saving)
        }
        .padding(14)
    }

    // MARK: Pieces

    private func artworkBox(size: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let img = model.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.3, weight: .ultraLight)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.4)))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k + ":").foregroundStyle(.secondary).frame(width: 82, alignment: .trailing)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }

    private func date(_ t: Double) -> String {
        t > 0 ? Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened) : "—"
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing).gridColumnAlignment(.trailing)
    }

    private func textField(_ f: GetInfoModel.Field) -> some View {
        TextField(model.isMixed(f) ? "Mixed" : "", text: model.binding(f))
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func field(_ title: String, _ f: GetInfoModel.Field, span: Bool) -> some View {
        GridRow {
            label(title)
            textField(f).gridCellColumns(3)
        }
    }

    private var genreField: some View {
        HStack(spacing: 2) {
            textField(.genre)
            Menu {
                ForEach(BrowserModelLink.genres, id: \.self) { g in
                    Button(g) { model.values[.genre] = g }
                }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
        }
    }
}

/// What Get Info needs from the main window's browser (play order for Previous/Next and the
/// library's genres), without passing the model around.
@MainActor
enum BrowserModelLink {
    static weak var browser: BrowserModel?
    static var order: [String] { browser?.visibleIDs ?? [] }
    static var genres: [String] {
        Array(Set(LibraryStore.shared.tracks.map(\.genre).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
