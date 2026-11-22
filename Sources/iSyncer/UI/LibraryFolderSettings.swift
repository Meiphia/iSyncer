import AppKit
import SwiftUI

@MainActor
struct LibraryFolderSettings: View {
    @ObservedObject private var library = LibraryStore.shared
    @State private var selected: URL?
    @State private var pendingRemoval: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media folders").font(.headline)
            Text("Music, videos, podcasts, and audiobooks from these folders appear together in your library.")
                .foregroundStyle(.secondary)
            List(library.libraryFolders, id: \.self, selection: $selected) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent).fontWeight(.medium)
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if !LibraryFolders.available(folder) {
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .tag(folder)
            }
            .overlay { if library.libraryFolders.isEmpty { Text("Add a folder to start your library.").foregroundStyle(.secondary) } }
            HStack {
                Button("Add Folder…", action: add)
                Button("Remove") { pendingRemoval = selected }
                    .disabled(selected == nil)
                Spacer()
                Button("Rescan") { library.scan() }
                    .disabled(library.libraryFolders.isEmpty)
            }
            .disabled(library.foldersBusy)
            if let folder = library.downloadFolder {
                Text("New podcast downloads and imported files are saved in the first folder: " + folder.path)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(library.isScanning || library.isScanningVideos ? library.scanStatus : "Unavailable folders keep their library entries until they reconnect. Removing a folder leaves its files on disk.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .alert("Remove Library Folder?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { folder in
            Button("Cancel", role: .cancel) {}
            Button("Remove Folder", role: .destructive) {
                run { try library.removeFolder(folder) }
                selected = nil
            }
        } message: { folder in
            Text("Removes \(folder.lastPathComponent) and its entries from iSyncer and your playlist selections. Files stay on disk. This changes what is eligible for your next iPod sync.")
        }
        .alert("Couldn’t Update Library Folders", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folders"
        if panel.runModal() == .OK { run { try library.addFolders(panel.urls) } }
    }

    private func run(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
}
