import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CollectionWindows {
    private static var galleryWindow: NSWindowController?

    static func gallery(_ track: Track) {
        galleryWindow?.close()
        let view = ArtworkGallery(track: track, collection: .shared).interfaceTypography()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Artwork — " + track.album
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 520, height: 400)
        window.center()
        galleryWindow = NSWindowController(window: window)
        galleryWindow?.showWindow(nil)
    }
}

@MainActor
struct ArtistPages: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerEngine
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var collection = LibraryCollection.shared
    @State private var selected: String?
    @State private var editing = false
    @State private var canonical = ""
    @State private var aliases = ""
    @State private var error: String?

    @State private var music: [Track] = []
    @State private var artists: [String] = []
    @State private var artistTracks: [Track] = []
    @State private var editions: [LibraryEdition] = []
    private var current: String? {
        selected.flatMap { artists.contains($0) ? $0 : nil } ??
            browser.artist.map(collection.artist).flatMap { artists.contains($0) ? $0 : nil } ?? artists.first
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                GlossyHeader(title: "Artists")
                List(artists.filter { browser.search.isEmpty || $0.localizedCaseInsensitiveContains(browser.search) },
                     id: \.self, selection: $selected) {
                    Text($0.isEmpty ? "Unknown Artist" : $0).tag($0)
                }
                .listStyle(.plain)
            }.frame(minWidth: 120, idealWidth: 180, maxWidth: 260)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(current ?? "Artists").font(.largeTitle.bold())
                            Text("\(editions.count) albums · \(artistTracks.count) tracks").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Link Artist Names…", action: beginEditing).disabled(current == nil)
                    }
                    let names = Set(artistTracks.flatMap { [$0.artist, $0.displayAlbumArtist] }).filter {
                        collection.artist($0) == current && !$0.isEmpty
                    }.sorted()
                    if names.count > 1 {
                        Text("Also credited as " + names.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    ForEach(editions) { edition in
                        HStack(alignment: .top, spacing: 16) {
                            AlbumTile(album: AlbumSummary(name: edition.first.album, year: edition.first.year,
                                                         count: edition.tracks.count, first: edition.first), artworkSize: 112)
                                .onTapGesture { CollectionWindows.gallery(edition.first) }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(edition.first.album).font(.headline)
                                Text([edition.first.classicEditionLabel, edition.first.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Play") { player.play(queue: edition.tracks.map(\.id), startAt: 0) }
                                    Button("Add to Queue") { player.enqueue(edition.tracks.map(\.id)) }
                                    Button("Artwork…") { CollectionWindows.gallery(edition.first) }
                                    AlbumQualityMenu(track: edition.first)
                                }
                                DisclosureGroup("Tracks") {
                                    ForEach(edition.tracks) { track in
                                        Button {
                                            player.play(queue: edition.tracks.map(\.id), startAt: edition.tracks.firstIndex(of: track) ?? 0)
                                        } label: {
                                            HStack {
                                                Text("\(track.discNumber > 1 ? "\(track.discNumber)." : "")\(track.trackNumber)  \(track.title)")
                                                Spacer()
                                                Text(Format.duration(track.duration)).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    if editions.isEmpty { ContentUnavailableView("No Albums", systemImage: "person.crop.square") }
                }.padding(18)
            }.frame(minWidth: 330)
        }
        .background(Color.white)
        .onReceive(library.$tracks) { tracks in music = tracks.filter(\.isMusic); rebuild() }
        .onChange(of: collection.revision) { _, _ in rebuild() }
        .onChange(of: selected) { _, _ in rebuild() }
        .onChange(of: browser.artist) { _, _ in selected = nil; rebuild() }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link Artist Names").font(.headline)
                TextField("Artist page name", text: $canonical)
                Text("Names and aliases, one per line").foregroundStyle(.secondary)
                TextEditor(text: $aliases).frame(height: 125).border(Color.gray.opacity(0.3))
                Text("Linked names share an artist page. File tags keep their credited artist names.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Unlink Listed Names") {
                        do {
                            for name in aliases.components(separatedBy: .newlines) where !name.isEmpty { try collection.unlink(name) }
                            editing = false
                        } catch { self.error = error.localizedDescription }
                    }
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        do {
                            try collection.setArtist(canonical, aliases: aliases.components(separatedBy: .newlines))
                            selected = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                            editing = false
                        } catch { self.error = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction).disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 470)
        }
        .alert("Couldn’t Save Artist Names", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func beginEditing() {
        canonical = current ?? ""
        aliases = Set(music.flatMap { [$0.artist, $0.displayAlbumArtist] }.filter {
            !$0.isEmpty && collection.artist($0) == current
        }).sorted().joined(separator: "\n")
        editing = true
    }

    private func rebuild() {
        artists = Set(music.map { collection.artist($0.displayAlbumArtist) }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        artistTracks = music.filter {
            collection.artist($0.displayAlbumArtist) == current || collection.artist($0.artist) == current
        }
        editions = LibraryEdition.editions(in: artistTracks).sorted {
            $0.first.year == $1.first.year ? $0.first.album < $1.first.album : $0.first.year < $1.first.year
        }
    }
}

@MainActor
struct ArtworkGallery: View {
    let track: Track
    @ObservedObject var collection: LibraryCollection
    @State private var label = "Front Cover"
    @State private var error: String?
    @State private var defaultImage: NSImage?

    var body: some View {
        let gallery = collection.gallery(for: track.classicEditionKey)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(track.album).font(.title2.bold())
                Spacer()
                TextField("Artwork label", text: $label).frame(width: 130)
                Button("Add Images…", action: add)
            }
            Text("Select the artwork to display in iSyncer and sync to the iPod. Additional images stay in the gallery.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 18) {
                    VStack {
                        preview(defaultImage)
                        Text("From Music Files")
                        Button(gallery.selected == nil ? "Selected" : "Use This Cover") {
                            run { try collection.select(nil, edition: track.classicEditionKey) }
                        }.disabled(gallery.selected == nil)
                    }
                    ForEach(gallery.pictures) { picture in
                        VStack {
                            preview(NSImage(contentsOf: collection.pictureURL(picture)))
                            Text(picture.label).lineLimit(1)
                            HStack {
                                Button(gallery.selected == picture.id ? "Selected" : "Use Cover") {
                                    run { try collection.select(picture.id, edition: track.classicEditionKey) }
                                }.disabled(gallery.selected == picture.id)
                                Button(role: .destructive) {
                                    run { try collection.remove(picture, edition: track.classicEditionKey) }
                                } label: { Image(systemName: "trash") }.help("Remove from gallery")
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .task(id: track.id) { defaultImage = await ArtworkLoader.shared.originalImage(for: track) }
        .alert("Couldn’t Update Artwork", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func preview(_ image: NSImage?) -> some View {
        ZStack {
            Color.gray.opacity(0.1)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
        }.frame(height: 145)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if let url = LibraryStore.shared.url(for: track) { panel.directoryURL = url.deletingLastPathComponent() }
        guard panel.runModal() == .OK else { return }
        run {
            for url in panel.urls { try collection.addPicture(url, label: panel.urls.count == 1 ? label : url.deletingPathExtension().lastPathComponent,
                                                             edition: track.classicEditionKey) }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct ExpandedNowPlaying: View {
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore
    @Binding var visible: Bool
    @ObservedObject private var art = ArtworkLoader.shared
    @State private var image: NSImage?
    @State private var tab = "Queue"
    @State private var backdrop = Color.gray.opacity(0.15)

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Now Playing").font(.headline)
                Spacer()
                Button("Close") { visible = false }
            }
            HStack(spacing: 22) {
                GeometryReader { bounds in
                    ZStack {
                        Color.clear
                        if let image { Image(nsImage: image).resizable().scaledToFit() }
                        else { Image(systemName: "music.note").font(.system(size: 72)).foregroundStyle(.secondary) }
                    }.frame(width: bounds.size.width, height: bounds.size.height)
                }
                .frame(minWidth: 160)
                VStack(alignment: .leading, spacing: 12) {
                    Text(player.current?.title ?? "Nothing Playing").font(.title.bold()).lineLimit(2)
                    Text(player.current?.artist ?? "").font(.title3)
                    Text(player.current?.album ?? "").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                           in: 0...max(1, player.duration))
                        .disabled(player.current == nil)
                    HStack {
                        Text(Format.duration(player.position))
                        Spacer()
                        Text(Format.duration(player.duration))
                    }.font(.caption).monospacedDigit()
                    HStack(spacing: 22) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                    }.font(.title2).buttonStyle(.plain)
                    if let current = player.current {
                        Button("Artwork Gallery…") { CollectionWindows.gallery(current) }
                    }
                    Picker("Panel", selection: $tab) {
                        Text("Queue").tag("Queue")
                        Text("Lyrics").tag("Lyrics")
                    }.pickerStyle(.segmented)
                    if tab == "Lyrics" {
                        LyricsPane(player: player)
                    } else {
                        List(player.upcoming, id: \.offset) { item in
                            if let track = library.track(item.id) {
                                Button {
                                    player.playUpcoming(at: item.offset, id: item.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(track.title)
                                        Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                    }
                }.frame(minWidth: 235, maxWidth: 360)
            }
        }
        .padding(20)
        .background(LinearGradient(colors: [backdrop, .white], startPoint: .topLeading, endPoint: .bottomTrailing))
        .task(id: [player.current?.id ?? "", String(art.podcastRevision)]) {
            guard let track = player.current else { image = nil; return }
            image = await art.image(for: track)
            backdrop = Self.color(from: image)
        }
    }

    private static func color(from image: NSImage?) -> Color {
        guard let image, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return .gray.opacity(0.15) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0).map { Color(nsColor: $0).opacity(0.35) } ?? .gray.opacity(0.15)
    }
}

@MainActor
struct AlbumQualityPicker: View {
    let edition: LibraryEdition
    let device: ClassicDevice
    @ObservedObject var devices: DeviceManager

    var body: some View {
        let settings = devices.settings(for: device)
        Picker("iPod Quality", selection: Binding(
            get: { devices.settings(for: device).albumAACBitrates?[edition.id] ?? -1 },
            set: { value in
                var next = devices.settings(for: device)
                next.setAlbumBitrate(value < 0 ? nil : value, edition: edition.id)
                devices.setSettings(next, for: device)
            }
        )) {
            Text("Use iPod Default").tag(-1)
            Text("Original Files").tag(0)
            ForEach(ClassicEncoding.bitrates, id: \.self) { Text("\($0) kbps AAC").tag($0) }
        }
        let estimate = edition.tracks.reduce(Int64(0)) { sum, track in
            let rate = settings.aacBitrate(for: track)
            return sum + (rate > 0 && ClassicEncoding.shouldEncode(track)
                ? Int64(max(0, track.duration) * Double(rate) * 125) : track.size)
        }
        Text("Estimated transfer size · \(Format.bytes(estimate))")
            .font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor
struct AlbumQualityMenu: View {
    let track: Track
    @ObservedObject private var devices = DeviceManager.shared

    var body: some View {
        Menu("iPod Quality") {
            if devices.connected.isEmpty {
                Text("Connect an iPod to set album quality")
            } else {
                ForEach(devices.connected) { device in
                    Menu(device.value.name) {
                        ForEach([-1, 0] + ClassicEncoding.bitrates, id: \.self) { value in
                            Button(value == -1 ? "Use iPod Default" : value == 0 ? "Original Files" : "\(value) kbps AAC") {
                                var settings = devices.settings(for: device)
                                settings.setAlbumBitrate(value < 0 ? nil : value, edition: track.classicEditionKey)
                                devices.setSettings(settings, for: device)
                            }
                        }
                    }
                }
            }
        }.disabled(devices.busy)
    }
}
