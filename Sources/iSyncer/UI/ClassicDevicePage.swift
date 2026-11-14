import ClassicSync
import AppKit
import SwiftUI

@MainActor
struct ClassicDevicePage: View {
    @Environment(\.interfaceTextSize) private var textSize
    private enum Tab: String, CaseIterable {
        case summary = "Summary", music = "Music", movies = "Movies", tv = "TV Shows"
        case podcasts = "Podcasts", audiobooks = "Audiobooks", contents = "On This iPod"
    }

    let id: UUID
    @ObservedObject var devices: DeviceManager
    @ObservedObject var library: LibraryStore
    @ObservedObject private var watchHistory = VideoWatchHistory.shared
    @ObservedObject private var subscriptions = PodcastSubscriptions.shared
    @State private var tab = Tab.summary
    @State private var confirming = false
    @State private var showPodcastDownload = false
    @State private var podcastShowForOptions: String?
    @State private var search = ""
    @State private var contentType = ClassicMediaKind.music
    @State private var selectedContents = Set<Int>()
    private enum Details: Identifiable {
        case preview([SyncItem])
        case results(DeviceSyncReport)

        var id: Int {
            switch self {
            case .preview: 0
            case .results: 1
            }
        }
    }

    @State private var details: Details?
    @State private var listeningChanges: [ListeningChange] = []
    @State private var showingListening = false
    @State private var retainedShow: String?
    @State private var showingBackups = false
    @State private var restorePreview: ClassicRestorePreview?
    @State private var restoreDate: Date?
    @State private var deviceOnly = false

    var body: some View {
        if let device = devices.device(id) {
            let plan = devices.preview(for: id)
            VStack(spacing: 0) {
                tabBar(device)
                if tab == .contents {
                    contents(device)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            switch tab {
                            case .summary: summary(device)
                            case .music: music(device)
                            case .movies: movies(device)
                            case .tv: shows(device)
                            case .podcasts: podcasts(device)
                            case .audiobooks: audiobooks(device)
                            case .contents: EmptyView()
                            }
                            if let issue = device.value.syncIssue {
                                Label(issue, systemImage: "exclamationmark.triangle")
                            } else if let plan {
                                preview(plan)
                            }
                        }
                        .padding(25)
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                footer(device, plan: plan)
            }
            .font(textSize.font(12))
            .background(.white)
            .onChange(of: tab) { search = "" }
            .onChange(of: contentType) { selectedContents = [] }
            .sheet(item: $details) { detail in
                switch detail {
                case .preview(let items):
                    SyncDetailsSheet(title: "Sync Preview", items: items)
                case .results(let report):
                    SyncDetailsSheet(title: "Sync Results", items: report.items, report: report,
                                     retry: !library.isScanning && !library.isScanningVideos && library.libraryRoot != nil && report.items.contains { $0.action == .skip && $0.sourceURL != nil } ? {
                        details = nil
                        Task { await devices.retryFailures(device, library: library, report: report) }
                    } : nil)
                }
            }
            .sheet(isPresented: $showPodcastDownload) { PodcastDownloadSheet(library: library) }
            .sheet(isPresented: $showingBackups) {
                backupSheet(device)
            }
            .sheet(item: Binding(
                get: { devices.playbackConflict(for: device.id) },
                set: { if $0 == nil, devices.playbackConflict(for: device.id) != nil { devices.cancelPlaybackConflict() } }
            )) { request in
                PlaybackConflictSheet(conflicts: request.changes, cancel: devices.cancelPlaybackConflict) { choices in
                    Task { await devices.resolvePlaybackConflict(request, choices: choices, library: library) }
                }
            }
            .sheet(isPresented: $showingListening) {
                ListeningImportSheet(changes: listeningChanges) { library.applyListeningChanges($0) }
            }
            .confirmationDialog("Sync to iPod?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Sync to iPod") { Task { await devices.sync(device) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Apply the previewed changes after backing up the current iPod database.")
            }
        } else {
            ContentUnavailableView("iPod Disconnected", systemImage: "ipod")
        }
    }

    private func tabBar(_ device: ClassicDevice) -> some View {
        HStack(spacing: 6) {
            Button { devices.eject(device) } label: {
                Label(device.value.name, systemImage: "eject.fill").lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(devices.busy)
            .help("Eject iPod")
            Divider().frame(height: 13).padding(.horizontal, 3)
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue)
                        .font(textSize.bold(11))
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(tab == item ? Theme.hex(0xC0C0C0) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 27 + textSize.extra)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
    }

    private func summary(_ device: ClassicDevice) -> some View {
        let value = device.value
        return VStack(alignment: .leading, spacing: 13) {
            Text(value.name).font(textSize.bold(16))
            panel {
                HStack(alignment: .top, spacing: 19) {
                    Image(systemName: "ipod").font(.system(size: 64, weight: .light))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(value.name).bold()
                        Text(value.generation)
                        Text("Capacity: \(Format.bytes(value.capacity))")
                        Text("\(value.trackCount.formatted()) items on iPod")
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Software Version \(value.firmware)").bold()
                        Text("Apple firmware")
                        Button("Eject iPod") { devices.eject(device) }
                            .buttonStyle(ChromeButtonStyle())
                            .disabled(devices.busy)
                    }
                }
            }
            Text("Options").font(textSize.bold(14))
            panel {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Sync only checked songs and videos", isOn: setting(\.checkedOnly, device))
                    Toggle("Use Album Artist as Artist on the iPod", isOn: $devices.useAlbumArtistForArtist)
                    Toggle("Import play counts when an iPod connects", isOn: $devices.automaticallyImportPlays)
                    Button("Review iPod Ratings…") {
                        Task {
                            if let changes = await devices.readListening(device, library: library) {
                                listeningChanges = changes
                                showingListening = true
                            }
                        }
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(library.libraryRoot == nil || device.value.syncIssue != nil || library.isScanning)
                    Button("Import iPod Plays") {
                        Task { await devices.importPlays(device, library: library) }
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(device.value.syncIssue != nil || library.libraryRoot == nil || library.isScanning)
                    .help("Imports play counts and queues recent timestamped plays when device scrobbling is enabled in Last.fm settings.")
                    if let result = devices.playImportResults[value.settingsID] {
                        Text(result).foregroundStyle(.secondary)
                    }
                    Button("Database Backups…") {
                        restorePreview = nil
                        restoreDate = nil
                        showingBackups = true
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(device.value.syncIssue != nil)
                    Button("Remove Default Playlists…") {
                        Task { await devices.previewDefaultPlaylistRemoval(device, library: library) }
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(device.value.syncIssue != nil)
                }
                .disabled(devices.busy)
            }
        }
    }

    private func backupSheet(_ device: ClassicDevice) -> some View {
        let backups = devices.backups(for: device)
        return VStack(alignment: .leading, spacing: 12) {
            Text("iPod Database Backups").font(.headline)
            Text("Restores the library index. Media files stay on the iPod.")
                .foregroundStyle(.secondary)
            if backups.isEmpty {
                ContentUnavailableView("No Database Backups", systemImage: "clock.arrow.circlepath")
            } else {
                List(backups) { backup in
                    HStack {
                        Text(backup.date.formatted(date: .abbreviated, time: .standard))
                        Spacer()
                        Button("Preview Restore") {
                            restorePreview = nil
                            restoreDate = nil
                            Task {
                                restorePreview = await devices.reviewRestore(backup, for: device)
                                if restorePreview != nil { restoreDate = backup.date }
                            }
                        }.disabled(devices.busy)
                    }
                }
            }
            if let preview = restorePreview, let date = restoreDate {
                Text("Restore from \(date.formatted())").font(.subheadline.bold())
                Text("\(preview.currentTracks) current entries → \(preview.backupTracks) backup entries")
                if preview.unlistedFiles > 0 {
                    Text("\(preview.unlistedFiles) current media files will stay on disk and disappear from the iPod library.")
                }
                if preview.missingFiles > 0 {
                    Text("\(preview.missingFiles) files in the backup are missing or changed. This backup cannot be restored.")
                        .foregroundStyle(.red)
                }
                if preview.positionalPlayLogExists {
                    Text("The iPod has a play-count log tied to the current track order. Choose a backup with the same track order.")
                        .foregroundStyle(.red)
                } else if !preview.canRestore && preview.missingFiles == 0 {
                    Text("This backup already matches the iPod database.").foregroundStyle(.secondary)
                }
            }
            HStack {
                if devices.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { showingBackups = false }
                if let preview = restorePreview, preview.canRestore {
                    Button("Restore Database") {
                        showingBackups = false
                        Task { await devices.restore(preview) }
                    }.disabled(devices.busy).buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
        .padding(18)
        .frame(width: 530, height: 440)
    }

    private func music(_ device: ClassicDevice) -> some View {
        let tracks = library.tracks.filter(\.isMusic)
        let playlists = library.playlists + library.smartListsAsPlaylists()
        let albums = Dictionary(grouping: tracks.filter { !$0.album.isEmpty }, by: \.classicAlbumKey)
        let albumItems = albums.flatMap { key, tracks in
            let editions = Dictionary(grouping: tracks, by: \.classicEditionKey)
            return editions.compactMap { edition, members -> Choice? in
                guard let track = members.first else { return nil }
                let title = "\(track.album) — \(track.displayAlbumArtist)"
                return Choice(key: editions.count == 1 ? key : edition,
                              title: editions.count == 1 ? title : "\(title) · \(track.classicEditionLabel)")
            }
        }
        return VStack(alignment: .leading, spacing: 13) {
            mediaHeading("Sync Music", count: "\(tracks.count.formatted()) songs", enabled: setting(\.music, device))
            panel {
                VStack(alignment: .leading, spacing: 7) {
                    radio("Entire music library", selected: !devices.settings(for: device).selectedMusic) {
                        setting(\.selectedMusic, device).wrappedValue = false
                    }
                    radio("Selected playlists, artists, albums and genres", selected: devices.settings(for: device).selectedMusic) {
                        setting(\.selectedMusic, device).wrappedValue = true
                    }
                    if devices.settings(for: device).selectedMusic {
                        Toggle("Fill remaining space with complete albums", isOn: Binding(
                            get: { devices.settings(for: device).fillRemainingSpace == true },
                            set: { setting(\.fillRemainingSpace, device).wrappedValue = $0 }
                        ))
                        if devices.settings(for: device).fillRemainingSpace == true {
                            let reserve = devices.settings(for: device).reserveGB ?? 2
                            Stepper("Leave \(reserve) GB free after filling", value: Binding(
                                get: { reserve }, set: { setting(\.reserveGB, device).wrappedValue = $0 }
                            ), in: 0...250)
                            Text("Copies selected media first and keeps your existing iPod music while filling.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(devices.busy || !devices.settings(for: device).music)
            }
            Group {
                let selected = devices.settings(for: device).selectedMusic
                if !selected {
                    Text("Checking an item switches to selected music. A song is included if it matches any checked item.")
                        .foregroundStyle(.secondary)
                }
                if selected && devices.settings(for: device).fillRemainingSpace != true {
                    Text("Preview Sync lists iSyncer-managed songs that will be removed from this iPod.")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 18) {
                        choices("Playlists", playlists.map { Choice(key: $0.id.uuidString, title: $0.name) }, musicSelection(\.playlists, device))
                        choices("Artists", unique(tracks.map(\.displayAlbumArtist)), musicSelection(\.artists, device))
                    }
                    HStack(alignment: .top, spacing: 18) {
                        choices("Genres", unique(tracks.map(\.genre)), musicSelection(\.genres, device))
                        choices("Albums", albumItems, albumSelection(device, tracks: tracks))
                    }
                }
                .disabled(devices.busy || !devices.settings(for: device).music)
            }
        }
    }

    private func movies(_ device: ClassicDevice) -> some View {
        let list = library.videos.filter { $0.kind != .tv }
        return VStack(alignment: .leading, spacing: 13) {
            mediaHeading("Sync Movies", count: "\(list.count.formatted()) videos", enabled: setting(\.movies, device))
            Text("Choose videos from your local media library. Put MP4 files in Movies, TV Shows, or Videos. Incompatible video is converted during preview.")
                .foregroundStyle(.secondary)
            choices("Movies", list.map { Choice(key: $0.id, title: $0.displayTitle) }, setting(\.movieIDs, device))
                .disabled(devices.busy || !devices.settings(for: device).movies)
            videoExclusions(device, tv: false)
        }
    }

    private func shows(_ device: ClassicDevice) -> some View {
        let list = library.videos.filter { $0.kind == .tv && !$0.show.isEmpty }
        let selection = devices.settings(for: device)
        let count = list.filter { selection.includesTVEpisode($0) && (!selection.checkedOnly || library.isVideoChecked($0.id)) }.count
        return VStack(alignment: .leading, spacing: 13) {
            mediaHeading("Sync TV Shows", count: "\(count.formatted()) of \(list.count.formatted()) episodes selected", enabled: setting(\.tvShows, device))
            Text("Expand a show to choose seasons or individual episodes. Incompatible video is converted during preview.")
                .foregroundStyle(.secondary)
            TVSyncPicker(episodes: list, search: search, selection: Binding(
                get: { devices.settings(for: device) },
                set: { devices.setSettings($0, for: device) }
            ))
                .disabled(devices.busy || !devices.settings(for: device).tvShows)
            if !selection.showNames.isEmpty {
                tvRetentionOptions(device, shows: selection.showNames.sorted(), episodes: list)
                    .disabled(devices.busy || !selection.tvShows)
            }
            videoExclusions(device, tv: true)
        }
    }

    private func tvRetentionOptions(_ device: ClassicDevice, shows: [String], episodes: [VideoItem]) -> some View {
        let show = retainedShow.flatMap { shows.contains($0) ? $0 : nil } ?? shows[0]
        let policy = Binding<TVRetention>(
            get: { devices.settings(for: device).tvRetention?[show] ?? TVRetention() },
            set: { rule in
                var settings = devices.settings(for: device)
                var policies = settings.tvRetention ?? [:]
                policies[show] = rule.limit != nil ? rule : nil
                settings.tvRetention = policies.isEmpty ? nil : policies
                devices.setSettings(settings, for: device)
            }
        )
        return panel {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Episode rules for", selection: Binding(get: { show }, set: { retainedShow = $0 })) {
                    ForEach(shows, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Sync the next unwatched episodes", isOn: Binding(
                    get: { policy.wrappedValue.limit != nil },
                    set: { policy.wrappedValue.limit = $0 ? 3 : nil }
                ))
                if let limit = policy.wrappedValue.limit {
                    Stepper("Keep the next \(limit) unwatched episodes", value: Binding(
                        get: { limit }, set: { policy.wrappedValue.limit = $0 }
                    ), in: 1...100)
                    Text("Pinned episodes stay on this iPod. Preview lists which iSyncer copies will be removed.")
                        .foregroundStyle(.secondary)
                    choices("Pinned Episodes", episodes.filter { $0.show == show }.sorted(by: VideoItem.episodeOrder).map {
                        let watched = watchHistory.state(at: library.url(forVideo: $0)).watched ? " · Watched" : ""
                        let prefix = $0.season == 0 ? "Specials" : "S\($0.season)"
                        return Choice(key: $0.id, title: "\(prefix) · \($0.displayTitle)\(watched)")
                    }, policy.pinned, filtered: false)
                }
            }
        }
    }

    private func podcasts(_ device: ClassicDevice) -> some View {
        let shows = Dictionary(grouping: library.tracks.filter { $0.podcastShow != nil }, by: { $0.podcastShow ?? "" })
        let selected = devices.settings(for: device).podcastNames
        let showNames = Set(shows.keys).union(subscriptions.shows.map(\.show))
        let chosenShows = showNames.filter(selected.contains).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 13) {
            mediaHeading("Sync Podcasts", count: "\(shows.values.reduce(0) { $0 + $1.count }.formatted()) episodes", enabled: setting(\.podcasts, device))
            HStack {
                Text("Download episodes from an RSS feed or add audio to your library’s Podcasts folder.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Find & Download Podcasts…") { showPodcastDownload = true }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(library.libraryRoot == nil || devices.busy)
            }
            Group {
                choices("Podcasts", unique(Array(showNames)), setting(\.podcastNames, device))
                if !chosenShows.isEmpty {
                    let show = podcastShowForOptions.flatMap { chosenShows.contains($0) ? $0 : nil } ?? chosenShows[0]
                    panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Episode options for", selection: Binding(
                                get: { show }, set: { podcastShowForOptions = $0 }
                            )) {
                                ForEach(chosenShows, id: \.self) { Text($0).tag($0) }
                            }
                            podcastOptions(device, show: show, episodes: shows[show] ?? [])
                        }
                    }
                }
            }
            .disabled(devices.busy || !devices.settings(for: device).podcasts)
        }
    }

    private func podcastOptions(_ device: ClassicDevice, show: String, episodes: [Track]) -> some View {
        let policy = Binding<PodcastRetention>(
            get: { devices.settings(for: device).podcastRetention?[show] ?? PodcastRetention() },
            set: {
                var settings = devices.settings(for: device)
                settings.setPodcastRetention($0, for: show)
                devices.setSettings(settings, for: device)
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Keep", selection: Binding(
                get: {
                    let value = policy.wrappedValue
                    if value.unplayedOnly == true { return value.limit == nil ? "unplayed" : "catchup" }
                    return value.limit == nil ? "manual" : "latest"
                },
                set: { mode in
                    var value = policy.wrappedValue
                    let unplayed = mode == "unplayed" || mode == "catchup"
                    if value.unplayedOnly != true && unplayed { value.removeFinished = false }
                    if !unplayed { value.removeFinished = nil }
                    value.unplayedOnly = unplayed ? true : nil
                    value.limit = mode == "latest" || mode == "catchup" ? value.limit ?? 5 : nil
                    policy.wrappedValue = value
                }
            )) {
                Text("All checked episodes").tag("manual")
                Text("Latest episodes").tag("latest")
                Text("All unplayed episodes").tag("unplayed")
                Text("Catch Up").tag("catchup")
            }
            if let limit = policy.wrappedValue.limit {
                let unplayed = policy.wrappedValue.unplayedOnly == true
                Stepper(unplayed ? "Keep latest \(limit) unplayed episodes" : "Keep latest \(limit) episodes",
                        value: Binding(
                            get: { policy.wrappedValue.limit ?? 5 },
                            set: { policy.wrappedValue.limit = $0 }
                        ), in: 1...max(100, episodes.count, limit))
            }
            if policy.wrappedValue.unplayedOnly == true {
                Toggle("Remove finished episodes from this iPod", isOn: Binding(
                    get: { policy.wrappedValue.removesFinished },
                    set: { policy.wrappedValue.removeFinished = $0 }
                ))
                Text("In-progress episodes are kept alongside the newest unplayed episodes.")
                    .foregroundStyle(.secondary)
            }
            if policy.wrappedValue.limit != nil || policy.wrappedValue.unplayedOnly == true {
                Text("Pinned episodes stay on this iPod. Sync Preview lists managed copies to remove.")
                    .foregroundStyle(.secondary)
                choices("Pinned Episodes", episodes.map { Choice(key: $0.id, title: $0.title) }, policy.pinned, filtered: false)
            }
        }
    }

    private func audiobooks(_ device: ClassicDevice) -> some View {
        let books = library.tracks.compactMap(\.audiobookTitle)
        return VStack(alignment: .leading, spacing: 13) {
            mediaHeading("Sync Audiobooks", count: "\(Set(books).count.formatted()) books", enabled: setting(\.audiobooks, device))
            choices("Audiobooks", unique(books), setting(\.audiobookNames, device))
                .disabled(devices.busy || !devices.settings(for: device).audiobooks)
        }
    }

    private func mediaHeading(_ title: String, count: String, enabled: Binding<Bool>) -> some View {
        HStack {
            Toggle(title, isOn: enabled).font(textSize.bold(15)).disabled(devices.busy)
            Text(count).foregroundStyle(.secondary)
            Spacer()
            TextField("Filter", text: $search).frame(width: 160)
        }
    }

    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "largecircle.fill.circle" : "circle")
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func contents(_ device: ClassicDevice) -> some View {
        let removable = contentType == .movie || contentType == .tvShow
        let local = deviceOnly ? Set(library.tracks.map {
            deviceMatchKey($0.title, $0.artist, $0.podcastShow ?? $0.audiobookTitle ?? $0.album)
        } + library.tracks.map {
            deviceMatchKey($0.title, $0.displayAlbumArtist, $0.album)
        }) : []
        let localVideos = deviceOnly ? Set(library.videos.map(\.displayTitle)) : []
        let rows = device.value.contents.filter {
            let onMac = removable ? localVideos.contains($0.title) : local.contains(deviceMatchKey($0.title, $0.artist, $0.album))
            return $0.kind == contentType && (!deviceOnly || !onMac) && (search.isEmpty || [$0.title, $0.artist, $0.album].contains {
                $0.localizedCaseInsensitiveContains(search)
            })
        }
        let selection = rows.filter { selectedContents.contains($0.id) }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("Media", selection: $contentType) {
                    Text("Music").tag(ClassicMediaKind.music)
                    Text("Movies").tag(ClassicMediaKind.movie)
                    Text("TV Shows").tag(ClassicMediaKind.tvShow)
                    Text("Podcasts").tag(ClassicMediaKind.podcast)
                    Text("Audiobooks").tag(ClassicMediaKind.audiobook)
                }
                .fixedSize()
                Spacer()
                Toggle("Only on iPod", isOn: $deviceOnly)
                Button("Recover Selected…") { recover(selection, device: device) }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(selection.isEmpty || devices.busy)
                TextField("Filter", text: $search).frame(width: 160)
            }
            if removable {
                HStack {
                    removalMenu("Remove from iPod…", device: device, items: selection)
                    if let episode = selection.first, contentType == .tvShow, !episode.album.isEmpty {
                        let season = device.value.contents.filter {
                            $0.kind == .tvShow && $0.album == episode.album && $0.season == episode.season
                        }
                        removalMenu("Remove Season \(episode.season)…", device: device, items: season)
                        .disabled(!selection.allSatisfy { $0.album == episode.album && $0.season == episode.season })
                    }
                }
                .disabled(selection.isEmpty || devices.busy || device.value.syncIssue != nil)
            }
            if removable, let plan = devices.preview(for: device.id), plan.items.contains(where: { $0.action == .remove }) {
                Text(plan.videoExclusions.isEmpty
                     ? "Mac copies stay in your library. Videos still selected for sync can return on the next sync."
                     : "Mac copies stay in your library. These videos will be excluded from future syncs to this iPod.")
                    .foregroundStyle(.secondary)
            }
            Table(rows, selection: $selectedContents) {
                TableColumn("Name", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("Album", value: \.album)
                TableColumn("Season") { item in Text(item.kind == .tvShow ? String(item.season) : "") }.width(55)
            }
            .alternatingRowBackgrounds()
        }
        .padding(14)
    }

    private func deviceMatchKey(_ title: String, _ artist: String, _ album: String) -> [String] {
        [title, artist, album].map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    private func recover(_ items: [ClassicDeviceItem], device: ClassicDevice) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Recover Here"
        if panel.runModal() == .OK, let folder = panel.url {
            Task { await devices.recover(items, from: device, to: folder) }
        }
    }

    private func preview(_ plan: SyncPlan) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sync Preview").bold()
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    previewCount("Files to copy", plan.pending.count,
                                 detail: plan.bytes > 0 ? Format.bytes(plan.bytes) : "")
                    previewCount("Media to remove", plan.removedTrackCount,
                                 detail: plan.reclaimableBytes > 0 ? "\(Format.bytes(plan.reclaimableBytes)) to free" : "")
                    previewCount("Metadata and artwork", plan.metadataUpdateCount, detail: "existing media items")
                    previewCount("Bookmarks to iPod", plan.bookmarkUpdateCount)
                    previewCount("Bookmarks to Mac", devices.playbackImportCount(for: id))
                }
                .padding(.vertical, 4)
                if plan.videoReplacementCount > 0 { Text("\(plan.videoReplacementCount.formatted()) copies replace older video encodes") }
                if plan.repairsPodcastIndex { Text("Repair Podcasts index on the iPod") }
                if plan.artworkCandidates > 0 { Text("\(plan.artworkCandidates.formatted()) items to check for artwork") }
                if plan.removedVideoArtworkCount > 0 { Text("\(plan.removedVideoArtworkCount.formatted()) video covers to clear") }
                if plan.playlistCount > 0 { Text("\(plan.playlistCount.formatted()) playlists to update") }
                if plan.removedPlaylistCount > 0 { Text("\(plan.removedPlaylistCount.formatted()) playlists to remove") }
                if !plan.removedDefaultPlaylistNames.isEmpty {
                    Text(plan.removedDefaultPlaylistNames.joined(separator: ", ")).foregroundStyle(.secondary)
                }
                if !devices.skipped.isEmpty { Text("\(devices.skipped.count.formatted()) items skipped") }
                if plan.hasChanges && !plan.canFit { Label("The iPod is low on free space.", systemImage: "exclamationmark.triangle") }
                if !devices.hasPlaybackImports(for: id) && !plan.hasChanges { Text("No changes to apply") }
            }
        }
    }

    private func previewCount(_ label: String, _ count: Int, detail: String = "") -> some View {
        GridRow {
            Text(label)
            Text(count.formatted()).monospacedDigit().bold().gridColumnAlignment(.trailing)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func footer(_ device: ClassicDevice, plan: SyncPlan?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !devices.status.isEmpty {
                Text(devices.status).lineLimit(1).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    capacity(device.value).frame(minWidth: 100)
                    footerActions(device, plan: plan)
                }
                VStack(alignment: .trailing, spacing: 8) {
                    capacity(device.value)
                    HStack(spacing: 8) { footerActions(device, plan: plan) }
                }
            }
        }
        .padding(10)
        .background(Theme.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
    }

    @ViewBuilder
    private func footerActions(_ device: ClassicDevice, plan: SyncPlan?) -> some View {
        if !devices.busy, let plan, !plan.items.isEmpty || !devices.skipped.isEmpty || devices.hasPlaybackImports(for: id) {
            Button("View Preview…") {
                details = .preview(plan.items + devices.playbackImportItems(for: id) + devices.skipped)
            }.buttonStyle(ChromeButtonStyle())
        }
        if !devices.busy, let report = devices.lastReports[device.value.settingsID] {
            Button("Last Results…") { details = .results(report) }.buttonStyle(ChromeButtonStyle())
        }
        if devices.canStop {
            Button("Stop Sync & Save") { devices.stopAndSave() }.buttonStyle(ChromeButtonStyle())
        } else if let plan, plan.hasChanges || devices.hasPlaybackImports(for: id), !devices.busy {
            Button("Clear Preview") { devices.discardPreview() }.buttonStyle(ChromeButtonStyle())
            Button("Apply") { confirming = true }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(plan.hasChanges && !plan.canFit)
        } else {
            if plan != nil && !devices.busy {
                Button("Clear Preview") { devices.discardPreview() }.buttonStyle(ChromeButtonStyle())
            }
            Button("Preview Sync") { Task { await devices.prepare(device, library: library) } }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(devices.busy || library.isScanning || library.isScanningVideos || library.libraryRoot == nil || device.value.syncIssue != nil)
        }
    }

    private func capacity(_ device: Device) -> some View {
        let used = max(0, device.capacity - device.available)
        let audio = device.mediaBytes[.music, default: 0] + device.mediaBytes[.audiobook, default: 0]
        let video = device.mediaBytes[.movie, default: 0] + device.mediaBytes[.tvShow, default: 0]
        let podcast = device.mediaBytes[.podcast, default: 0]
        let segments: [(String, Int64, Color)] = [
            ("Audio", audio, Theme.hex(0x408FDC)), ("Video", video, Theme.hex(0x9C74C8)),
            ("Podcasts", podcast, Theme.hex(0x67AF79)),
            ("Other", max(0, used - audio - video - podcast), Theme.hex(0xE5BB61))
        ]
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Theme.hex(0xD6D6D6)
                HStack(spacing: 0) {
                    ForEach(segments, id: \.0) { name, size, color in
                        color.frame(width: geometry.size.width * Double(size) / Double(max(1, max(used, audio + video + podcast) + device.available)))
                            .help("\(name): \(Format.bytes(size))")
                    }
                }
                Text("\(Format.bytes(device.available)) Free")
                    .font(textSize.bold(10))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.chromeLine.opacity(0.6)) }
        }
        .frame(height: 18 + textSize.extra)
        .accessibilityLabel("\(Format.bytes(device.available)) free of \(Format.bytes(device.capacity))")
    }

    private func setting<T>(_ key: WritableKeyPath<ClassicSyncSettings, T>, _ device: ClassicDevice) -> Binding<T> {
        Binding(get: { devices.settings(for: device)[keyPath: key] }, set: { value in
            var settings = devices.settings(for: device)
            settings[keyPath: key] = value
            devices.setSettings(settings, for: device)
        })
    }

    private func musicSelection(_ key: WritableKeyPath<ClassicSyncSettings, Set<String>>, _ device: ClassicDevice) -> Binding<Set<String>> {
        Binding(get: { devices.settings(for: device)[keyPath: key] }, set: { value in
            var settings = devices.settings(for: device)
            settings[keyPath: key] = value
            settings.selectedMusic = true
            devices.setSettings(settings, for: device)
        })
    }

    private func albumSelection(_ device: ClassicDevice, tracks: [Track]) -> Binding<Set<String>> {
        let groups = Dictionary(grouping: tracks, by: \.classicAlbumKey)
        return Binding(get: {
            var keys = devices.settings(for: device).albums
            for (album, tracks) in groups {
                let editions = Set(tracks.map(\.classicEditionKey))
                if editions.count > 1, keys.remove(album) != nil { keys.formUnion(editions) }
                if editions.count == 1, let edition = editions.first, keys.remove(edition) != nil { keys.insert(album) }
            }
            return keys
        }, set: { musicSelection(\.albums, device).wrappedValue = $0 })
    }

    private func removalMenu(_ title: String, device: ClassicDevice, items: [ClassicDeviceItem]) -> some View {
        Menu(title) {
            Button("Remove Once") { Task { await devices.previewVideoRemoval(device, items: items) } }
            Button("Remove and Exclude from Sync") {
                Task { await devices.previewVideoRemoval(device, items: items, exclude: true) }
            }
        }
    }

    private func videoExclusions(_ device: ClassicDevice, tv: Bool) -> some View {
        let excluded = (devices.settings(for: device).excludedVideos ?? [:])
            .filter { $0.key.hasPrefix(tv ? "tv:" : "movie:") }
        return Group {
            if !excluded.isEmpty {
                DisclosureGroup("Excluded from Sync (\(excluded.count))") {
                    ForEach(excluded.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(excluded[key] ?? key)
                            Spacer()
                            Button("Allow Sync") {
                                var settings = devices.settings(for: device)
                                settings.excludedVideos?.removeValue(forKey: key)
                                devices.setSettings(settings, for: device)
                            }
                        }
                    }
                }
                .disabled(devices.busy)
            }
        }
    }

    private struct Choice: Identifiable {
        let key: String
        let title: String
        var id: String { key }
    }

    private func unique(_ strings: [String]) -> [Choice] {
        Set(strings.filter { !$0.isEmpty }).map { Choice(key: $0, title: $0) }
    }

    private func choices(_ title: String, _ options: [Choice], _ selection: Binding<Set<String>>, filtered: Bool = true) -> some View {
        let visible = options.filter { !filtered || search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(textSize.bold(13))
                Spacer()
                Button("Select All") { selection.wrappedValue.formUnion(visible.map(\.key)) }
                    .buttonStyle(.plain).foregroundStyle(.blue).disabled(visible.isEmpty)
                Button("Clear") { selection.wrappedValue.subtract(visible.map(\.key)) }
                    .buttonStyle(.plain).foregroundStyle(.blue).disabled(selection.wrappedValue.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        Toggle(item.title, isOn: Binding(get: { selection.wrappedValue.contains(item.key) }, set: {
                            if $0 { selection.wrappedValue.insert(item.key) }
                            else { selection.wrappedValue.remove(item.key) }
                        }))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 20 + textSize.extra)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index.isMultiple(of: 2) ? Theme.hex(0xEDF1F7) : .white)
                    }
                    if visible.isEmpty { Text("No items").foregroundStyle(.secondary).padding(7) }
                }
            }
            .frame(height: 168)
            .background(.white)
            .border(Theme.hex(0xB8B8B8))
        }
        .frame(maxWidth: .infinity)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hex(0xF2F2F2))
            .border(Theme.hex(0xD2D2D2))
    }
}

private struct SyncDetailsSheet: View {
    let title: String
    let items: [SyncItem]
    var report: DeviceSyncReport? = nil
    var retry: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var action: SyncItem.Action?

    var body: some View {
        let visible = items.filter {
            (action == nil || $0.action == action) &&
            (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.detail.localizedCaseInsensitiveContains(filter))
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let report {
                Text("\(report.device) · \(report.date.formatted()) · \(report.status)").foregroundStyle(.secondary)
            }
            HStack {
                if let report {
                    Button("Copy Report") {
                        let rows = report.items.map { "\($0.action.rawValue): \($0.title) \($0.detail)" }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(([report.device, report.date.formatted(), report.status] + rows)
                            .joined(separator: "\n"), forType: .string)
                    }
                }
                Picker("Action", selection: $action) {
                    Text("All (\(items.count))").tag(nil as SyncItem.Action?)
                    ForEach(SyncItem.Action.allCases, id: \.self) { action in
                        Text("\(action.rawValue) (\(items.filter { $0.action == action }.count))").tag(Optional(action))
                    }
                }
                TextField("Filter items", text: $filter)
            }
            if visible.isEmpty {
                ContentUnavailableView(items.isEmpty ? "No Changes to Report" : "No Matching Items", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(visible.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.action.rawValue).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) }
                            if let changes = item.metadataChanges, !changes.isEmpty {
                                DisclosureGroup(item.action == .bookmark || item.action == .importBookmark ? "Compare Progress" : "Compare Metadata") { MetadataComparison(changes: changes) }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if let retry { Button("Preview Failed Items", action: retry) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 610, height: 440)
    }
}

struct MetadataComparison: View {
    let changes: [SyncMetadataChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(changes, id: \.field) { change in
                Text(change.field).fontWeight(.semibold)
                HStack(alignment: .top, spacing: 12) {
                    value("Before", text: change.before, image: change.beforeImage)
                    value("After", text: change.after, image: change.afterImage)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func value(_ label: String, text: String, image: Data?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let image, let thumbnail = NSImage(data: image) {
                Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 56, height: 56)
            } else {
                Text(text.isEmpty ? "None" : text).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
