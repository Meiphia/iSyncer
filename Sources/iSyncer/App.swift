import SwiftUI
import AppKit

@main
struct iSyncerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var browser = BrowserModel()
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var lyrics = LyricsPresentation.shared
    @State private var showPodcastDownload = false
    @State private var showInbox = false
    @State private var relinkError: String?
    @State private var relinkPreview: LibraryRelink?
    @State private var relinking = false

    var body: some Scene {
        Window("iSyncer", id: "main") {
            MainView(library: .shared, player: .shared, devices: .shared, browser: browser)
                .sheet(isPresented: $showPodcastDownload) { PodcastDownloadSheet(library: .shared) }
                .sheet(isPresented: $showInbox) { ImportInbox(library: .shared) }
                .sheet(item: $relinkPreview) { preview in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Relink Media Folder").font(.headline)
                        Text(preview.destination.path).textSelection(.enabled)
                        Text("\(preview.matched.formatted()) matched · \(preview.missing.count.formatted()) missing")
                        if !preview.missing.isEmpty {
                            Text("Missing files can be restored to the listed paths later. Automatic device removals and playlist updates are paused while files are missing.")
                                .foregroundStyle(.secondary)
                            List(preview.missing, id: \.self) { Text($0).textSelection(.enabled) }
                                .frame(height: 200)
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { relinkPreview = nil }.keyboardShortcut(.cancelAction)
                            Button("Relink") {
                                relinkPreview = nil
                                relinking = true
                                Task {
                                    defer { relinking = false }
                                    do { try await library.relinkRoot(preview) }
                                    catch { relinkError = error.localizedDescription }
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(preview.matched == 0 && !preview.paths.isEmpty)
                        }
                    }
                    .padding(20)
                    .frame(width: 560)
                }
                .alert("Could Not Relink Library", isPresented: Binding(
                    get: { relinkError != nil }, set: { if !$0 { relinkError = nil } }
                )) { Button("OK") { relinkError = nil } } message: { Text(relinkError ?? "") }
                .interfaceTypography()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") {
                    let id = LibraryStore.shared.createPlaylist(name: "untitled playlist")
                    browser.source = .playlist(id)
                }
                .keyboardShortcut("n")
                Button("New Smart Playlist…") {
                    SmartPlaylistEditor.shared.open { id in browser.source = .smartList(id) }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Add Media Folders…") { chooseLibraryFolder(.shared) }
                    .keyboardShortcut("o")
                Button("Rescan Media Library") { LibraryStore.shared.scan() }
                    .keyboardShortcut("r")
                Menu("Library Backup & Export") {
                    Button("Export Library Backup…") { LibraryBackupController.shared.export() }
                    Button("Restore Library Backup…") { LibraryBackupController.shared.restore() }
                    Button("Export Playlists as M3U8…") { LibraryBackupController.shared.exportPlaylists() }
                }
                Button("Import Inbox…") { showInbox = true }
                    .disabled(library.libraryRoot == nil)
                Button("Relink Media Folder…") { relink() }
                    .disabled(library.libraryRoot == nil || library.isScanning || library.isScanningVideos || relinking)
                Button("Download Podcast from RSS…") { showPodcastDownload = true }
                Divider()
                Button("Analyze Loudness (ReplayGain)") { LoudnessAnalyzer.shared.analyze() }
                Button("Analyze Loudness of Selection") {
                    LoudnessAnalyzer.shared.analyze(Array(browser.selection))
                }
                .disabled(browser.selection.isEmpty)
            }
            CommandMenu("Controls") {
                Button("Play/Pause") { PlayerEngine.shared.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Next Song") { PlayerEngine.shared.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Song") { PlayerEngine.shared.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Volume Up") { PlayerEngine.shared.volume = min(1, PlayerEngine.shared.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Volume Down") { PlayerEngine.shared.volume = max(0, PlayerEngine.shared.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                Divider()
                Button("Shuffle") { PlayerEngine.shared.shuffle.toggle() }
                Button("Repeat: Off / All / One") { PlayerEngine.shared.cycleRepeat() }
                Divider()
                Button("Show Current Song") {
                    if let c = PlayerEngine.shared.current {
                        if !browser.visibleIDs.contains(c.id) { browser.source = .library; browser.search = ""
                            browser.genre = nil }
                        browser.selection = [c.id]
                        browser.revealRequest += 1
                    }
                }
                .keyboardShortcut("l")
                Button("Party Shuffle") { browser.source = .partyShuffle }
                Button("Library Health") { browser.source = .health }
                Menu("Rediscover") {
                    ForEach(RediscoverMode.allCases, id: \.self) { mode in
                        Menu(mode.rawValue) {
                            Button("Play") { mode.run(library: .shared, save: false) }
                            Button("Save as Playlist") { mode.run(library: .shared, save: true) }
                        }
                    }
                }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Get Info") {
                    let sel = browser.selection
                    let ids = browser.visibleIDs.filter { sel.contains($0) }
                    GetInfoController.shared.show(ids: ids.isEmpty ? Array(sel) : ids)
                }
                .keyboardShortcut("i")
                .disabled(browser.selection.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Column Browser") { browser.showColumnBrowser.toggle() }
                    .keyboardShortcut("b")
                Button(browser.showCoverFlow ? "Close Cover Flow" : "Show Cover Flow") {
                    browser.showCoverFlow.toggle()
                }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Show Artwork") { browser.showArtwork.toggle() }
                    .keyboardShortcut("g")
                Button("Show Album Artwork") { browser.showAlbumArtwork.toggle() }
                Button("Expanded Now Playing") { browser.showExpandedPlayer.toggle() }
                Divider()
                Button("Equalizer") { EqualizerWindowController.shared.toggle() }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Visualizer") { browser.showVisualizer.toggle() }
                    .keyboardShortcut("t")
                Button(lyrics.isVisible ? "Hide Lyrics" : "Show Lyrics") { lyrics.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Mini Player") { MiniPlayerController.shared.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().interfaceTypography()
        }
    }

    private func relink() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Relink Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relinking = true
        Task {
            defer { relinking = false }
            do { relinkPreview = try await library.previewRelink(url) }
            catch { relinkError = error.localizedDescription }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The look is mid-2000s Aqua: always light.
        NSApp.appearance = NSAppearance(named: .aqua)
        LibraryStore.shared.load()
        DeviceManager.shared.start()
        _ = PlayerEngine.shared
        PlayerEngine.shared.restoreState()
        PodcastSubscriptions.shared.start(library: .shared)
        _ = LastFM.shared   // sends any scrobbles still waiting
        if LibraryStore.shared.libraryRoot != nil {
            LibraryStore.shared.scan()   // incremental: only new/changed files are read
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DeviceManager.shared.busy {
            DeviceManager.shared.message = "Wait for the iPod operation to finish before quitting."
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerEngine.shared.saveState()
        LibraryStore.shared.saveNowBlocking()
    }
}
