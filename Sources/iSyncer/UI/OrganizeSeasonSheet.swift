import SwiftUI

struct EpisodeOrganization: Identifiable {
    let id = UUID()
    let episodes: [VideoItem]
}

struct OrganizeSeasonSheet: View {
    @ObservedObject var library: LibraryStore
    let organization: EpisodeOrganization
    @Environment(\.dismiss) private var dismiss
    @State private var season = ""
    @State private var number = ""
    @State private var offsetMode = false
    @State private var preview: [PlannedEpisodeMove]?
    @State private var error: String?

    private var episodes: [VideoItem] {
        organization.episodes.sorted(by: VideoItem.episodeOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organize Season").font(.headline)
            Text(episodes.first?.show ?? "").foregroundStyle(.secondary)
            HStack {
                TextField("Destination season", text: $season).frame(width: 155)
                Picker("Numbering", selection: $offsetMode) {
                    Text("Start at episode").tag(false)
                    Text("Offset episode numbers").tag(true)
                }.fixedSize()
                TextField(offsetMode ? "Offset" : "First episode", text: $number).frame(width: 72)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let preview {
                List(preview, id: \.previous.id) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(change.previous.id).foregroundStyle(.secondary)
                        Text(change.updated.id).fontWeight(.medium)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                }
                if preview.isEmpty { Text("No files to move.").foregroundStyle(.secondary) }
            } else {
                List(episodes) { episode in Text(episode.displayTitle) }
            }
            HStack {
                Button("Preview Moves", action: prepare)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move Files", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview?.isEmpty != false)
            }
        }
        .padding(20)
        .frame(width: 650, height: 450)
        .onAppear {
            season = String(episodes.first?.season ?? 1)
            number = String(max(1, episodes.first?.episode ?? 1))
        }
        .onChange(of: season) { preview = nil; error = nil }
        .onChange(of: number) { preview = nil; error = nil }
        .onChange(of: offsetMode) { number = offsetMode ? "0" : String(max(1, episodes.first?.episode ?? 1)) }
    }

    private func edits() -> [EpisodeNumberEdit]? {
        guard let season = Int(season), let number = Int(number), (-999...999).contains(number) else { return nil }
        if offsetMode && episodes.contains(where: { $0.episode == 0 }) { return nil }
        return episodes.enumerated().map { index, video in
            EpisodeNumberEdit(video: video, season: season, episode: number + (offsetMode ? video.episode : index))
        }
    }

    private func prepare() {
        preview = nil
        error = nil
        guard let edits = edits() else {
            error = "Enter valid numbers. Use Start at Episode for files without episode numbers."
            return
        }
        do { preview = try library.planEpisodeMoves(edits) }
        catch { self.error = error.localizedDescription }
    }

    private func apply() {
        guard let preview, !preview.isEmpty, let edits = edits() else { return }
        do {
            let current = try library.planEpisodeMoves(edits)
            guard current.map(\.files.destination) == preview.map(\.files.destination) else {
                self.preview = nil
                error = "The destination changed. Preview the moves again."
                return
            }
            try library.organizeEpisodes(edits)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
