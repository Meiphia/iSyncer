import AppKit
import SwiftUI

struct VideoHealthIssue: Identifiable {
    let title: String
    let detail: String
    let video: VideoItem
    var id: String { title + "\u{0}" + video.id }

    static func find(in videos: [VideoItem]) -> [Self] {
        let episodes = videos.filter { $0.kind == .tv }
        let duplicates = Dictionary(grouping: episodes.filter { $0.episode > 0 }, by: \.classicTVKey)
        let movies = Dictionary(grouping: videos.filter { $0.kind == .movie }) {
            [$0.title.precomposedStringWithCanonicalMapping.lowercased(), String($0.year)]
        }
        var issues: [Self] = []
        for video in episodes {
            if video.episode == 0 {
                issues.append(Self(title: "Missing episode number", detail: video.show, video: video))
            }
            if (duplicates[video.classicTVKey]?.count ?? 0) > 1 {
                issues.append(Self(title: "Duplicate episode number",
                                   detail: "\(video.show) · S\(video.season)E\(video.episode)", video: video))
            }
            if let folder = VideoScanner.folderSeason(for: video), folder != video.season {
                issues.append(Self(title: "Season folder mismatch",
                                   detail: "Season \(folder) folder · Season \(video.season) in filename", video: video))
            }
        }
        for copies in movies.values where copies.count > 1 {
            issues += copies.map { Self(title: "Possible duplicate movie", detail: $0.displayTitle, video: $0) }
        }
        return issues.sorted { ($0.title, $0.video.id) < ($1.title, $1.video.id) }
    }
}

struct VideoHealthView: View {
    @ObservedObject var library: LibraryStore
    var search: String
    @State private var editing: VideoItem?
    @State private var organization: EpisodeOrganization?

    var body: some View {
        let issues = VideoHealthIssue.find(in: library.videos).filter {
            search.isEmpty || [$0.title, $0.detail, $0.video.id].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        if library.isScanningVideos {
            ProgressView("Checking videos…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if issues.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No Video Issues Found" : "No Matching Issues", systemImage: "film")
        } else {
            List(issues) { issue in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.title).fontWeight(.semibold)
                        Text(issue.detail)
                        Text(issue.video.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Get Info…") { editing = issue.video }
                    if issue.video.kind == .tv {
                        Button("Organize…") { organization = EpisodeOrganization(episodes: [issue.video]) }
                    }
                    Button {
                        if let url = library.url(forVideo: issue.video) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: {
                        Image(systemName: "folder")
                    }.help("Show in Finder")
                }
                .padding(.vertical, 3)
            }
            .sheet(item: $editing) { video in
                if let url = library.url(forVideo: video) { VideoInfoSheet(library: library, video: video, url: url) }
            }
            .sheet(item: $organization) { value in
                OrganizeSeasonSheet(library: library, organization: value)
            }
        }
    }
}
