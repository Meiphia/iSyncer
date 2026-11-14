import SwiftUI

struct TVSyncPicker: View {
    @Environment(\.interfaceTextSize) private var textSize
    let episodes: [VideoItem]
    let search: String
    @Binding var selection: ClassicSyncSettings
    @State private var expandedShows: Set<String> = []
    @State private var expandedSeasons: [String: Set<Int>] = [:]
    @State private var collapsedSearchShows: Set<String> = []
    @State private var collapsedSearchSeasons: [String: Set<Int>] = [:]

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = Dictionary(grouping: episodes, by: \.show)
        let shows = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let matches = episodes.filter { episode in
            query.isEmpty || [episode.show, seasonTitle(episode.season), episode.displayTitle]
                .contains { $0.localizedStandardContains(query) }
        }
        let visible = Dictionary(grouping: matches, by: \.show)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("TV Shows").font(textSize.bold(13))
                Spacer()
                Button("Select All") { select(matches, included: true) }
                    .disabled(matches.isEmpty)
                Button("Clear") { select(matches, included: false) }
                    .disabled(!matches.contains(where: selection.includesTVEpisode))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shows, id: \.self) { show in
                        if let all = groups[show], let matching = visible[show] {
                            showRows(show, all: all, matching: matching, filtering: !query.isEmpty)
                        }
                    }
                    if matches.isEmpty { Text("No items").foregroundStyle(.secondary).padding(7) }
                }
            }
            .frame(height: 260)
            .background(.white)
            .border(Theme.hex(0xB8B8B8))
        }
        .onChange(of: query) {
            collapsedSearchShows = []
            collapsedSearchSeasons = [:]
        }
    }

    private func showRows(_ show: String, all: [VideoItem], matching: [VideoItem], filtering: Bool) -> some View {
        let expanded = filtering ? !collapsedSearchShows.contains(show) : expandedShows.contains(show)
        let seasons = Dictionary(grouping: all, by: \.season)
        let visible = Dictionary(grouping: matching, by: \.season)
        return Group {
            row(show, episodes: matching, level: 0, expanded: expanded, disclose: {
                if filtering { Self.toggle(show, in: &collapsedSearchShows) }
                else { Self.toggle(show, in: &expandedShows) }
            }) { included in
                if matching.count == all.count { selection.selectTVShow(show, included: included) }
                else { select(matching, included: included) }
            }
            if expanded {
                ForEach(visible.keys.sorted(), id: \.self) { season in
                    if let items = seasons[season], let shown = visible[season] {
                        let open = filtering ? !collapsedSearchSeasons[show, default: []].contains(season)
                            : expandedSeasons[show, default: []].contains(season)
                        row(seasonTitle(season), episodes: shown, level: 1, expanded: open, disclose: {
                            if filtering { Self.toggle(season, in: &collapsedSearchSeasons[show, default: []]) }
                            else { Self.toggle(season, in: &expandedSeasons[show, default: []]) }
                        }) { included in
                            if shown.count == items.count { selection.selectTVSeason(season, in: show, included: included) }
                            else { select(shown, included: included) }
                        }
                        if open {
                            ForEach(shown) { episode in
                                row(episode.displayTitle, episodes: [episode], level: 2) {
                                    selection.selectTVEpisode(episode, included: $0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, episodes: [VideoItem], level: Int,
                     expanded: Bool = false, disclose: (() -> Void)? = nil,
                     change: @escaping (Bool) -> Void) -> some View {
        let selected = episodes.filter(selection.includesTVEpisode).count
        let all = selected == episodes.count
        let mixed = !all && selected > 0
        return HStack(spacing: 5) {
            if let disclose {
                Button(action: disclose) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")
            } else {
                Color.clear.frame(width: 14)
            }
            Toggle(isOn: Binding(get: { all }, set: change)) { Text(title).lineLimit(1) }
                .toggleStyle(TVSelectionToggle(mixed: mixed))
            Spacer(minLength: 0)
            if disclose != nil {
                Text("\(selected) of \(episodes.count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(6 + level * 17))
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(level == 0 ? Theme.hex(0xEDF1F7) : level == 1 ? Theme.hex(0xF5F7FA) : .white)
    }

    private func select(_ episodes: [VideoItem], included: Bool) {
        var updated = selection
        let shows = Dictionary(grouping: self.episodes, by: \.show)
        for (show, matches) in Dictionary(grouping: episodes, by: \.show) {
            if matches.count == shows[show]?.count { updated.selectTVShow(show, included: included) }
            else { for episode in matches { updated.selectTVEpisode(episode, included: included) } }
        }
        selection = updated
    }

    private static func toggle<T: Hashable>(_ item: T, in set: inout Set<T>) {
        if set.remove(item) == nil { set.insert(item) }
    }

    private func seasonTitle(_ season: Int) -> String { season == 0 ? "Specials" : "Season \(season)" }
}

private struct TVSelectionToggle: ToggleStyle {
    let mixed: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mixed ? "minus.square.fill" : configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(mixed || configuration.isOn ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .accessibilityValue(mixed ? "Partially selected" : configuration.isOn ? "Selected" : "Unselected")
    }
}
