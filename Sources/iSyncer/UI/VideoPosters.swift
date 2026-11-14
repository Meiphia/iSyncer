import AppKit
import AVFoundation
import ClassicSync
import SwiftUI

@MainActor
struct VideoPreviewDetails: View {
    @Environment(\.interfaceTextSize) private var textSize
    let video: VideoItem
    let url: URL?
    var poster = false
    var showArtwork = false
    var revision = 0
    @State private var artwork: NSImage?
    @State private var duration = ""
    @State private var overview = ""

    var body: some View {
        Group {
            if poster {
                image.frame(width: 118, height: 164)
            } else {
                HStack(spacing: 10) {
                    image.frame(width: 91, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.displayTitle).font(textSize.bold(12)).lineLimit(1)
                        if !overview.isEmpty {
                            Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(duration).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .task(id: PreviewKey(url: url, modified: video.modified, revision: revision)) {
            guard let url else { return }
            artwork = nil
            duration = ""
            overview = ""
            let edit = LibraryStore.shared.videoMetadata(for: url)
            if showArtwork, let art = await Self.localShowArtwork(for: video, at: url), !Task.isCancelled {
                artwork = NSImage(data: art)
                if artwork != nil { return }
            }
            let detected = await VideoMetadataEdit.detected(at: url, isEpisode: video.kind == .tv)
            guard !Task.isCancelled else { return }
            artwork = (edit?.artwork ?? detected.artwork).flatMap(NSImage.init(data:))
            if poster { return }
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            duration = seconds.isFinite && seconds > 0 ? Format.duration(seconds) : ""
            overview = edit?.overview ?? detected.overview ?? ""
            if artwork == nil {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 140)
                if let frame = try? await generator.image(at: CMTime(seconds: seconds.isFinite ? min(15, seconds / 3) : 0, preferredTimescale: 600)),
                   !Task.isCancelled {
                    artwork = NSImage(cgImage: frame.image, size: .zero)
                }
            }
        }
    }

    private struct PreviewKey: Equatable {
        let url: URL?
        let modified: Double
        let revision: Int
    }

    private static func localShowArtwork(for video: VideoItem, at url: URL) async -> Data? {
        // Only walk directories represented in the library-relative path.
        let depth = video.id.split(separator: "/").dropLast().count
        return await Task.detached(priority: .utility) {
            var folder = url.deletingLastPathComponent()
            for _ in 0..<depth {
                if folder.lastPathComponent.localizedCaseInsensitiveCompare(video.show) == .orderedSame {
                    for name in ["poster.jpg", "poster.png", "folder.jpg", "cover.jpg"] {
                        if let art = VideoMetadataEdit.loadArtwork(from: folder.appending(path: name)) { return art }
                    }
                    break
                }
                folder.deleteLastPathComponent()
            }
            return nil
        }.value
    }

    private var image: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.hex(0xE6EAF1)
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(systemName: video.kind == .tv ? "tv" : "film")
                        .font(.system(size: poster ? 28 : 17)).foregroundStyle(.secondary)
                }
            }
        }.border(Theme.hex(0xB8BCC5))
    }
}
