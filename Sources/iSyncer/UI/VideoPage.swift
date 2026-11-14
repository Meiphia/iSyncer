import SwiftUI
import AppKit
import ClassicSync
import UniformTypeIdentifiers

/// Videos library: what was found, how it'll be laid out on the device, and checkboxes.
@MainActor
struct VideoPage: View {
    @Environment(\.interfaceTextSize) private var textSize
    @ObservedObject var library: LibraryStore
    let search: String
    @ObservedObject private var history = VideoWatchHistory.shared
    @AppStorage("videoPosterView") private var posters = true
    @State private var unwatched = false
    @State private var playing: VideoItem?
    @State private var posterShow: String?
    @State private var posterSeason: Int?
    @State private var collapsedPosterSeasons: [String: Set<Int>] = [:]
    @State private var selection = Set<VideoItem.ID>()
    @State private var editing: VideoItem?
    @State private var metadataBatch: TVMetadataBatch?
    @State private var sortOrder: [KeyPathComparator<VideoItem>] = []
    // Column browser: Category → Show / Movie / Folder → Season
    @State private var category: String?
    @State private var group: String?
    @State private var organization: EpisodeOrganization?
    @State private var season: String?
    @AppStorage("videoBrowserHeight") private var browserHeight: Double = 150

    var body: some View {
        if library.videos.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "film.stack").font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(Theme.hex(0x5A6B85))
                Text("No Videos").font(.system(size: 20, weight: .semibold))
                Text(library.isScanningVideos
                     ? "Looking for videos…"
                     : "Add movies and TV episodes to the Movies, TV, or Videos folders in your media library.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                if library.libraryRoot == nil {
                    Button("Choose Media Library…") { chooseLibraryFolder(library) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Picker("View", selection: $posters) {
                        Text("Posters").tag(true)
                        Text("List").tag(false)
                    }.pickerStyle(.segmented).fixedSize()
                    Spacer()
                    Toggle("Unwatched", isOn: $unwatched)
                }.padding(.horizontal, 10).padding(.vertical, 5).background(Theme.chrome)
                if posters {
                    posterBrowser
                } else {
                    PersistentSplit(autosaveName: "iSyncer.VideoBrowser", panes: [
                        .init(view: AnyView(VideoColumn(title: "Categories", allLabel: "All Videos", items: categoryItems, selection: $category)),
                              minWidth: 100, initialWidth: 200, holding: 255),
                        .init(view: AnyView(VideoColumn(title: groupTitle, allLabel: "All", items: groupItems, selection: $group,
                                                        metadataAction: { show in
                            guard category == nil || category == "TV",
                                  let video = library.videos.first(where: { $0.kind == .tv && $0.show == show }) else { return nil }
                            return { startMetadataBatch(for: video, season: nil) }
                        })),
                              minWidth: 100, initialWidth: 300, holding: 254),
                        .init(view: AnyView(VideoColumn(title: "Seasons", allLabel: "All Seasons", items: seasonItems, selection: $season,
                                                        metadataAction: { value in
                            guard let group, let number = Int(value),
                                  let video = library.videos.first(where: { $0.kind == .tv && $0.show == group }) else { return nil }
                            return { startMetadataBatch(for: video, season: number) }
                        })),
                              minWidth: 100, holding: 250)
                    ])
                    .frame(height: browserHeight)
                    SplitHandle(value: $browserHeight, range: 80...600)
                    table
                }
            }
            .onChange(of: category) { _, _ in group = nil; season = nil }
            .onChange(of: group) { _, _ in season = nil }
            .sheet(isPresented: Binding(get: { playing != nil }, set: { if !$0 { playing = nil } })) {
                if let video = playing, let url = library.url(forVideo: video) {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button("Done") { playing = nil }.keyboardShortcut(.cancelAction)
                        }.padding(8).background(Theme.glossyHeader)
                        LibraryVideoPlayer(video: video, url: url, next: nextEpisode(after: video)) { playing = $0 }
                            .id(video.id)
                    }
                }
            }
            .sheet(item: $organization) { value in
                OrganizeSeasonSheet(library: library, organization: value)
            }
            .sheet(item: $editing) { video in
                if let url = library.url(forVideo: video) {
                    VideoInfoSheet(library: library, video: video, url: url)
                }
            }
            .sheet(item: $metadataBatch) { batch in
                if let first = batch.videos.first {
                    VideoLookupSheet(video: first, batch: batch, rememberedMatch: library.rememberedTVMatch(for: first.show),
                                     onRemember: { library.rememberTVMatch($0, for: first.show) })
                }
            }
        }
    }

    // MARK: Column browser

    /// Second-column key: the show for TV, the film for movies, the folder for anything else.
    private func groupKey(_ v: VideoItem) -> String {
        switch v.kind {
        case .tv: return v.show
        case .movie: return v.displayTitle
        case .other: return ((v.id as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
    }

    private var searched: [VideoItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let videos = library.videos.filter { !unwatched || !watchState($0).watched }.map(displayVideo)
        guard !q.isEmpty else { return videos }
        return videos.filter { ($0.title + " " + $0.show + " " + $0.id).lowercased().contains(q) }
    }

    private func displayVideo(_ video: VideoItem) -> VideoItem {
        var item = video
        if let url = library.url(forVideo: item), let title = library.videoMetadata(for: url)?.title {
            item.title = title
        }
        return item
    }

    private var byCategory: [VideoItem] {
        guard let category else { return searched }
        return searched.filter { $0.kindLabel == category }
    }

    private var byGroup: [VideoItem] {
        guard let group else { return byCategory }
        return byCategory.filter { groupKey($0) == group }
    }

    private var categoryItems: [VideoColumn.Item] {
        let present = Set(searched.map(\.kindLabel))
        return [("TV", "TV Shows"), ("Movie", "Movies"), ("Other", "Other Videos")]
            .filter { present.contains($0.0) }
            .map { VideoColumn.Item(id: $0.0, label: $0.1) }
    }

    private var groupTitle: String {
        switch category {
        case "TV": return "Shows"
        case "Movie": return "Movies"
        case "Other": return "Folders"
        default: return "Titles"
        }
    }

    private var groupItems: [VideoColumn.Item] {
        Array(Set(byCategory.map(groupKey)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { VideoColumn.Item(id: $0, label: $0) }
    }

    /// Seasons only exist for TV; for movies this column stays empty.
    private var seasonItems: [VideoColumn.Item] {
        Array(Set(byGroup.filter { $0.kind == .tv }.map(\.season)))
            .sorted()
            .map { VideoColumn.Item(id: String($0), label: "Season \($0)") }
    }

    private var rows: [VideoItem] {
        var list = byGroup
        if let season, let n = Int(season) {
            list = list.filter { $0.kind == .tv && $0.season == n }
        }
        if !sortOrder.isEmpty { list.sort(using: sortOrder) }
        return list
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", sortUsing: KeyPathComparator(\VideoItem.id)) { (v: VideoItem) in
                Toggle("", isOn: Binding(
                    get: { library.isVideoChecked(v.id) },
                    set: { on in
                        let ids = selection.contains(v.id) && selection.count > 1 ? Array(selection) : [v.id]
                        library.setVideosChecked(ids, on)
                    }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            .width(20)
            TableColumn("Kind", value: \VideoItem.kindLabel)
                .width(min: 40, ideal: 50, max: 70)
            TableColumn("Title", value: \VideoItem.displayTitle) { (v: VideoItem) in
                Text(v.displayTitle).foregroundStyle(library.isVideoChecked(v.id) ? Color.primary : Color.secondary)
            }
            .width(min: 140, ideal: 260)
            TableColumn("Show", value: \VideoItem.show)
                .width(min: 80, ideal: 160)
            TableColumn("Season", value: \VideoItem.season) { (v: VideoItem) in
                Text(v.kind == .tv ? "\(v.season)" : "").monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 60)
            TableColumn("Year", value: \VideoItem.year) { (v: VideoItem) in
                Text(v.year > 0 ? String(v.year) : "").monospacedDigit()
            }
            .width(min: 36, ideal: 44, max: 60)
            TableColumn("Size", value: \VideoItem.size) { (v: VideoItem) in
                Text(Format.bytes(v.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Watched") { (v: VideoItem) in
                let state = watchState(v)
                if state.watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                else if state.fraction > 0 { ProgressView(value: state.fraction).frame(width: 55) }
            }.width(min: 55, ideal: 70, max: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.system(size: 11 + textSize.extra))
        .contextMenu(forSelectionType: VideoItem.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play") { open(ids) }.disabled(ids.count != 1)
                Button("Open in Default Player") { openExternally(ids) }
                Button("Mark as Watched") { mark(ids, watched: true) }
                Button("Mark as Unwatched") { mark(ids, watched: false) }
                if ids.count == 1, let video = library.videos.first(where: { ids.contains($0.id) }) {
                    Button("Get Info…") { editing = video }
                }
                let episodes = library.videos.filter { ids.contains($0.id) }
                if let first = episodes.first, first.kind == .tv, !first.show.isEmpty,
                   episodes.allSatisfy({ $0.kind == .tv && $0.show == first.show }) {
                    Button("Organize Season…") { organization = EpisodeOrganization(episodes: episodes) }
                    Menu("Find Metadata") {
                        if episodes.allSatisfy({ $0.season == first.season }) {
                            Button(first.season == 0 ? "Specials…" : "Season \(first.season)…") {
                                startMetadataBatch(for: first, season: first.season)
                            }
                        }
                        Button("Entire Show…") { startMetadataBatch(for: first, season: nil) }
                    }
                }
                Button("Check Selection") { library.setVideosChecked(Array(ids), true) }
                Button("Uncheck Selection") { library.setVideosChecked(Array(ids), false) }
                Button("Show in Finder") {
                    let urls = library.videos.filter { ids.contains($0.id) }.compactMap { library.url(forVideo: $0) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
        } primaryAction: { ids in
            open(ids)
        }
    }

    private func startMetadataBatch(for video: VideoItem, season: Int?) {
        guard let root = library.libraryRoot else { return }
        let episodes = library.videos.filter {
            $0.kind == .tv && $0.show == video.show && (season == nil || $0.season == season)
        }
        let scope = season.map { $0 == 0 ? "Specials" : "Season \($0)" } ?? "Entire Show"
        metadataBatch = TVMetadataBatch(videos: episodes, label: "\(video.show) · \(scope)", current: { item in
            guard library.libraryRoot == root, let url = library.url(forVideo: item) else { return nil }
            let saved = library.videoMetadata(for: url)
            let detected = await VideoMetadataEdit.detected(at: url, isEpisode: true)
            return VideoMetadataEdit(title: saved?.title ?? item.title, releaseDate: saved?.releaseDate ?? detected.releaseDate,
                                     artwork: saved?.artwork ?? detected.artwork, overview: saved?.overview ?? detected.overview)
        }) { updates in
            guard library.libraryRoot == root else { return ([], "The media library changed. Run the lookup again.") }
            return library.saveEpisodeMetadata(updates)
        }
    }

    private func watchState(_ video: VideoItem) -> VideoWatchHistory.State {
        history.state(at: library.url(forVideo: video))
    }

    private func mark(_ ids: Set<VideoItem.ID>, watched: Bool) {
        for id in ids {
            guard let url = library.url(forID: id) else { continue }
            history.update(url, seconds: 0, duration: 0, watched: watched)
        }
    }

    private func open(_ ids: Set<VideoItem.ID>) {
        guard ids.count == 1 else { return }
        playing = searched.first { ids.contains($0.id) }
    }

    private func openExternally(_ ids: Set<VideoItem.ID>) {
        for id in ids {
            if let url = library.url(forID: id) { NSWorkspace.shared.open(url) }
        }
    }

    private func nextEpisode(after video: VideoItem) -> VideoItem? {
        guard video.kind == .tv, !video.show.isEmpty else { return nil }
        return library.videos.filter { $0.kind == .tv && $0.show == video.show && VideoItem.episodeOrder(video, $0) }
            .min(by: VideoItem.episodeOrder)
    }

    private var posterBrowser: some View {
        let videos = searched
        let shows = Dictionary(grouping: videos.filter { $0.kind == .tv }, by: \.show)
        let inProgress = videos.filter { watchState($0).seconds > 0 && !watchState($0).watched }
            .sorted { watchState($0).updated > watchState($1).updated }
        return ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if posterShow == nil, videos.isEmpty {
                    ContentUnavailableView("No Matching Videos", systemImage: "film")
                }
                if let show = posterShow {
                    HStack {
                        Button("All Videos") { posterShow = nil; posterSeason = nil }
                        Text(show).font(.headline)
                        Spacer()
                        Button("Find Show Metadata…") {
                            if let first = shows[show]?.first { startMetadataBatch(for: first, season: nil) }
                        }.disabled(shows[show]?.isEmpty != false)
                        if let season = posterSeason {
                            Button("Organize Season…") {
                                organization = EpisodeOrganization(episodes: (shows[show] ?? []).filter { $0.season == season })
                            }
                        }
                        Picker("Season", selection: $posterSeason) {
                            Text("All Seasons").tag(nil as Int?)
                            ForEach(Set((shows[show] ?? []).map(\.season)).sorted(), id: \.self) { season in
                                Text(season == 0 ? "Specials" : "Season \(season)").tag(Optional(season))
                            }
                        }.fixedSize()
                    }
                    .padding(.horizontal, 12)
                    posterUpNext(for: show)
                    posterEpisodes(shows[show] ?? [], show: show)
                } else {
                    if !inProgress.isEmpty {
                        Text("Continue Watching").font(.headline)
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(inProgress.prefix(10)) { card($0, label: $0.title) { playing = $0 } }
                            }
                        }
                    }
                    if !shows.isEmpty {
                        Text("TV Shows").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), alignment: .top)], alignment: .leading, spacing: 14) {
                            ForEach(shows.keys.sorted(), id: \.self) { show in
                                if let first = shows[show]?.min(by: VideoItem.episodeOrder) {
                                    card(first, label: show, showArtwork: true) { _ in posterShow = show; posterSeason = nil }
                                }
                            }
                        }
                    }
                    let movies = videos.filter { $0.kind != .tv }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
                    if !movies.isEmpty {
                        Text("Movies & Other Videos").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), alignment: .top)], alignment: .leading, spacing: 14) {
                            ForEach(movies) { card($0, label: $0.displayTitle) { playing = $0 } }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, posterShow == nil ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.background(.white)
    }

    @ViewBuilder
    private func posterUpNext(for show: String) -> some View {
        let episodes = library.videos.filter { $0.kind == .tv && $0.show == show }
        if let next = VideoItem.upNext(in: episodes, state: watchState) {
            let episode = displayVideo(next.episode)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Up Next").font(textSize.bold(12))
                    Text(episode.title).font(textSize.font(12)).lineLimit(1)
                    Text(upNextDetail(episode, position: next.position))
                        .font(textSize.font(11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { playing = episode } label: {
                    Label(next.position > 0 ? "Resume" : "Play Episode", systemImage: "play.fill")
                        .fixedSize()
                }
                .buttonStyle(ChromeButtonStyle())
            }
            .padding(10)
            .background(Theme.hex(0xEDF2F9))
            .overlay { Rectangle().strokeBorder(Theme.chromeLine.opacity(0.25)) }
            .padding(.horizontal, 12)
        }
    }

    private func upNextDetail(_ episode: VideoItem, position: Double) -> String {
        var detail = episode.season == 0 ? "Specials" : "Season \(episode.season)"
        if episode.episode > 0 { detail += " · Episode \(episode.episode)" }
        if position > 0 { detail += " · \(Format.duration(position))" }
        return detail
    }

    private func posterEpisodes(_ showEpisodes: [VideoItem], show: String) -> some View {
        let visible = showEpisodes.filter { posterSeason == nil || posterSeason == $0.season }
            .sorted(by: VideoItem.episodeOrder)
        let groups = Dictionary(grouping: visible, by: \.season)
        let seasons = groups.keys.sorted { ($0 == 0 ? 1 : 0, $0) < ($1 == 0 ? 1 : 0, $1) }

        return Group {
            if visible.isEmpty {
                ContentUnavailableView("No Matching Episodes", systemImage: "tv")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(seasons, id: \.self) { season in
                        let episodes = groups[season, default: []]
                        let collapsed = collapsedPosterSeasons[show, default: []].contains(season)
                        Section {
                            if !collapsed {
                                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                                    posterEpisodeRow(episode)
                                        .background(index.isMultiple(of: 2) ? Color.white : Theme.hex(0xEDF2F9))
                                }
                            }
                        } header: {
                            posterSeasonHeader(season, show: show, collapsed: collapsed)
                                .padding(.top, season == seasons.first ? 0 : 12)
                        }
                    }
                }
            }
        }
    }

    private func posterSeasonHeader(_ season: Int, show: String, collapsed: Bool) -> some View {
        let label = season == 0 ? "Specials" : "Season \(season)"
        return Button {
            if collapsed {
                collapsedPosterSeasons[show, default: []].remove(season)
            } else {
                collapsedPosterSeasons[show, default: []].insert(season)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 11)
                    .accessibilityHidden(true)
                Text(label)
                    .font(textSize.bold(12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(Theme.glossyHeader)
            .overlay {
                Rectangle().strokeBorder(Theme.chromeLine.opacity(0.65), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .help(collapsed ? "Show episodes" : "Hide episodes")
    }

    private func posterEpisodeRow(_ episode: VideoItem) -> some View {
        let state = watchState(episode)
        return Button { playing = episode } label: {
            HStack {
                VideoPreviewDetails(video: episode, url: library.url(forVideo: episode), revision: library.videoMetadataRevision)
                if state.watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                else if state.fraction > 0 { ProgressView(value: state.fraction).frame(width: 45) }
            }.contentShape(Rectangle()).padding(6)
        }
        .buttonStyle(.plain)
        .contextMenu { posterMenu(episode) }
    }

    private func card(_ video: VideoItem, label: String, showArtwork: Bool = false, action: @escaping (VideoItem) -> Void) -> some View {
        Button { action(video) } label: {
            VStack(alignment: .leading, spacing: 4) {
                VideoPreviewDetails(video: video, url: library.url(forVideo: video), poster: true,
                                    showArtwork: showArtwork, revision: library.videoMetadataRevision)
                Text(label).font(textSize.bold(11)).lineLimit(2)
                if watchState(video).seconds > 0, !watchState(video).watched {
                    ProgressView(value: watchState(video).fraction).frame(width: 118)
                }
            }.frame(width: 118, alignment: .leading)
        }.buttonStyle(.plain).contextMenu { posterMenu(video) }
    }

    private func posterMenu(_ video: VideoItem) -> some View {
        Group {
            Button("Play") { playing = video }
            Button("Open in Default Player") { openExternally([video.id]) }
            Button("Get Info…") { editing = video }
            Button(watchState(video).watched ? "Mark as Unwatched" : "Mark as Watched") {
                mark([video.id], watched: !watchState(video).watched)
            }
        }
    }

}

@MainActor
struct VideoInfoSheet: View {
    @ObservedObject var library: LibraryStore
    let video: VideoItem
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var season = ""
    @State private var episode = ""
    @State private var overview = ""
    @State private var detectedOverview = ""
    @State private var savedOverview: String?
    @State private var findingMetadata = false
    @State private var releaseDate = Date()
    @State private var useReleaseDate = false
    @State private var detectedDate: Date?
    @State private var detectedArtwork: Data?
    @State private var artwork: Data?
    @State private var resetArtwork = false
    @State private var resetReleaseDate = false
    @State private var choosingArtwork = false
    @State private var loading = true
    @State private var error: String?

    private var renumbering: Bool {
        video.kind == .tv && (Int(season) != video.season || Int(episode) != video.episode)
    }

    private var newEpisodePath: String? {
        guard renumbering, let root = library.libraryRoot, let season = Int(season), let episode = Int(episode) else { return nil }
        return VideoScanner.episodePath(for: video, season: season, episode: episode, at: root)
    }

    private var lookupVideo: VideoItem {
        var draft = video
        if let value = Int(season) { draft.season = value }
        if let value = Int(episode) { draft.episode = value }
        return draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(video.kind == .tv ? "Episode Info" : "Video Info").font(.headline)
            if video.kind == .tv {
                Text(video.show)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Title").gridColumnAlignment(.trailing)
                    TextField("Title", text: $title).labelsHidden()
                }
                if video.kind == .tv {
                    GridRow {
                        Text("Season")
                        HStack(spacing: 10) {
                            TextField("Season", text: $season).labelsHidden().frame(width: 58)
                            Text("Episode")
                            TextField("Episode", text: $episode).labelsHidden().frame(width: 64)
                        }
                    }
                    if let path = newEpisodePath {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Text("Move to \(path)").foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    } else if !loading && renumbering {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Text("Season 0–99, episode 1–999.").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    Text("Description").padding(.top, 3)
                    TextEditor(text: $overview)
                        .frame(height: 84)
                        .border(.quaternary)
                        .accessibilityLabel("Description")
                }
                GridRow(alignment: .top) {
                    Text("Release date")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Override release date", isOn: $useReleaseDate)
                            .onChange(of: useReleaseDate) { _, enabled in
                                if !enabled { resetReleaseDate = true }
                            }
                        if useReleaseDate {
                            DatePicker("Release date", selection: $releaseDate, displayedComponents: .date)
                                .labelsHidden().environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        } else if let detectedDate {
                            Text(detectedDate, format: .iso8601.year().month().day())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    Text("Artwork")
                    HStack(spacing: 12) {
                        if let data = artwork ?? detectedArtwork, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 82)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Choose Artwork…") { choosingArtwork = true }
                            if artwork != nil {
                                Button("Use Detected Artwork") {
                                    artwork = nil
                                    resetArtwork = true
                                }
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(loading)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Button("Find Metadata…") { findingMetadata = true }.disabled(loading || (renumbering && newEpisodePath == nil))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(loading || (renumbering && newEpisodePath == nil) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            let edit = library.videoMetadata(for: url)
            title = edit?.title ?? video.title
            season = String(video.season)
            episode = String(video.episode)
            useReleaseDate = edit?.releaseDate != nil
            artwork = edit?.artwork
            resetArtwork = edit?.resetArtwork == true
            resetReleaseDate = edit?.resetReleaseDate == true
            let detected = await VideoMetadataEdit.detected(at: url, isEpisode: video.kind == .tv)
            detectedDate = detected.releaseDate
            detectedArtwork = detected.artwork
            detectedOverview = detected.overview ?? ""
            savedOverview = edit?.overview
            overview = savedOverview ?? detectedOverview
            releaseDate = edit?.releaseDate ?? detectedDate ?? Date()
            loading = false
        }
        .sheet(isPresented: $findingMetadata) {
            VideoLookupSheet(video: lookupVideo, rememberedMatch: library.rememberedTVMatch(for: video.show),
                             onRemember: { library.rememberTVMatch($0, for: video.show) },
                             onUse: { metadata, missingArtwork in
                if let title = metadata.title, !title.isEmpty { self.title = title }
                if let date = metadata.releaseDate {
                    releaseDate = date
                    useReleaseDate = true
                }
                if let overview = metadata.overview { self.overview = overview }
                if let artwork = metadata.artwork {
                    self.artwork = artwork
                    resetArtwork = false
                }
                error = missingArtwork ? "Metadata loaded. Artwork could not be downloaded." : nil
            })
        }
        .fileImporter(isPresented: $choosingArtwork, allowedContentTypes: [.image]) { result in
            do {
                let file = try result.get()
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                guard let data = VideoMetadataEdit.loadArtwork(from: file) else {
                    throw SyncError("Choose a readable image under 8 MB.")
                }
                artwork = data
                resetArtwork = false
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOverview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = cleanOverview == detectedOverview.trimmingCharacters(in: .whitespacesAndNewlines) &&
            savedOverview == nil ? nil : cleanOverview
        let metadata = VideoMetadataEdit(title: cleanTitle, releaseDate: useReleaseDate ? releaseDate : nil,
                                         artwork: artwork, resetArtwork: resetArtwork ? true : nil,
                                         resetReleaseDate: !useReleaseDate && resetReleaseDate ? true : nil,
                                         overview: description)
        do {
            if renumbering, let season = Int(season), let episode = Int(episode) {
                try library.renumberEpisode(video, season: season, episode: episode, saving: metadata)
            } else {
                try library.saveVideoMetadata(metadata, for: url)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// One column of the video browser, styled like the music column browser.
@MainActor
struct VideoColumn: View {
    @Environment(\.interfaceTextSize) private var textSize
    struct Item: Identifiable, Hashable {
        let id: String
        let label: String
    }

    let title: String
    let allLabel: String
    let items: [Item]
    @Binding var selection: String?
    var metadataAction: ((String) -> (() -> Void)?)? = nil

    private static let allTag = "\u{0}all"

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11 + textSize.extra, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(LinearGradient(colors: [Theme.hex(0xF4F4F4), Theme.hex(0xD9D9D9)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hex(0xA0A0A0)).frame(height: 1) }
            List(selection: Binding<String?>(
                get: { selection ?? Self.allTag },
                set: { selection = ($0 == Self.allTag) ? nil : $0 })) {
                Text("\(allLabel) (\(items.count.formatted()))")
                    .fontWeight(.semibold)
                    .tag(Self.allTag)
                ForEach(items) { item in
                    Text(item.label).tag(item.id)
                        .contextMenu {
                            if let action = metadataAction?(item.id) {
                                Button("Find Metadata…", action: action)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .font(.system(size: 11 + textSize.extra))
        }
    }
}
