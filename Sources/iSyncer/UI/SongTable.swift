import SwiftUI
import AppKit
import Combine

/// The song list: an AppKit table drawn in the iTunes 6 style. Columns can be resized,
/// reordered and shown/hidden (right-click the header), and the layout is remembered.
@MainActor
struct SongTable: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var library: LibraryStore
    let isPodcasts: Bool

    func makeCoordinator() -> SongTableCoordinator { SongTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = ITTableView()
        configureITTable(table)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        for spec in isPodcasts ? SongColumn.podcasts : SongColumn.all {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.headerCell = makeHeaderCell(spec.title)
            col.headerCell.alignment = spec.alignment
            col.width = spec.width
            col.minWidth = spec.minWidth
            col.maxWidth = spec.maxWidth
            col.isHidden = spec.hiddenByDefault
            col.headerToolTip = spec.title.isEmpty ? nil : spec.title
            if let key = spec.sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            col.resizingMask = spec.fixed ? [] : .userResizingMask
            table.addTableColumn(col)
        }
        table.autosaveName = isPodcasts ? "iSyncer.PodcastEpisodes" : "iSyncer.SongList"
        table.autosaveTableColumns = true
        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(SongTableCoordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onKey = { [weak c] event in c?.handleKey(event) ?? false }

        let menu = NSMenu()
        menu.delegate = c
        table.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = c
        table.headerView?.menu = headerMenu
        c.headerMenu = headerMenu

        c.table = table
        c.parent = self
        c.observePlayer()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(textSize: context.environment.interfaceTextSize)
    }
}

/// Column catalogue. `sortKey` matches TrackSort.
struct SongColumn {
    let id: String
    let title: String
    let width: CGFloat
    var minWidth: CGFloat = 30
    var maxWidth: CGFloat = 2000
    var sortKey: String?
    var alignment: NSTextAlignment = .left
    var hiddenByDefault = false
    var fixed = false

    static let all: [SongColumn] = [
        SongColumn(id: "check", title: "", width: 18, minWidth: 18, maxWidth: 18, fixed: true),
        SongColumn(id: "playing", title: "", width: 16, minWidth: 16, maxWidth: 16, fixed: true),
        SongColumn(id: "name", title: "Name", width: 240, minWidth: 60, sortKey: "title"),
        SongColumn(id: "time", title: "Time", width: 46, sortKey: "duration", alignment: .right),
        SongColumn(id: "artist", title: "Artist", width: 170, minWidth: 50, sortKey: "artist"),
        SongColumn(id: "album", title: "Album", width: 190, minWidth: 50, sortKey: "album"),
        SongColumn(id: "albumArtist", title: "Album Artist", width: 140, sortKey: "albumArtist", hiddenByDefault: true),
        SongColumn(id: "track", title: "Track #", width: 54, sortKey: "trackNumber", alignment: .right, hiddenByDefault: true),
        SongColumn(id: "genre", title: "Genre", width: 100, sortKey: "genre"),
        SongColumn(id: "rating", title: "My Rating", width: 68, minWidth: 64, sortKey: "rating"),
        SongColumn(id: "plays", title: "Play Count", width: 64, sortKey: "playCount", alignment: .right),
        SongColumn(id: "lastPlayed", title: "Last Played", width: 120, sortKey: "lastPlayed", hiddenByDefault: true),
        SongColumn(id: "dateAdded", title: "Date Added", width: 120, sortKey: "dateAdded", hiddenByDefault: true),
        SongColumn(id: "year", title: "Year", width: 42, sortKey: "year", alignment: .right),
        SongColumn(id: "kind", title: "Kind", width: 110, sortKey: "codec", hiddenByDefault: true),
        SongColumn(id: "bitrate", title: "Bit Rate", width: 70, sortKey: "bitrate", alignment: .right, hiddenByDefault: true),
        SongColumn(id: "size", title: "Size", width: 70, sortKey: "size", alignment: .right, hiddenByDefault: true)
    ]

    static let podcasts: [SongColumn] = all.compactMap { column in
        switch column.id {
        case "artist", "albumArtist", "genre", "track": return nil
        case "album": return SongColumn(id: "show", title: "Show", width: 190, minWidth: 50, sortKey: "podcastShow")
        default: return column
        }
    }
}

@MainActor
final class SongTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var parent: SongTable?
    weak var table: ITTableView?
    weak var headerMenu: NSMenu?

    private var rows: [Track] = []
    private var rowIndex: [String: Int] = [:]
    private var lastUnchecked: Set<String> = []
    private var lastSortKey: String?? = .none
    private var lastSortAscending = true
    private var lastReveal = 0
    private var updatingSelection = false
    private var playingID: String?
    private var cancellables = Set<AnyCancellable>()

    private var browser: BrowserModel? { parent?.browser }
    private var library: LibraryStore { LibraryStore.shared }
    private var player: PlayerEngine { PlayerEngine.shared }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: Sync with the model

    func observePlayer() {
        player.$current
            .map { $0?.id }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.playingChanged(id) }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadColumn("playing", rows: self?.playingRows() ?? []) }
            .store(in: &cancellables)
    }

    func sync(textSize: InterfaceTextSize) {
        guard let table, let browser else { return }
        let resized = table.updateTextSize(textSize)
        let newRows = browser.visible
        if newRows != rows {
            rows = newRows
            rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            table.reloadData()
        } else if library.unchecked != lastUnchecked || resized {
            updatingSelection = true
            table.reloadData()
            updatingSelection = false
        }
        lastUnchecked = library.unchecked

        // Sort indicator follows the model (it resets when the source changes).
        if lastSortKey != .some(browser.sortKey) || lastSortAscending != browser.sortAscending {
            lastSortKey = .some(browser.sortKey)
            lastSortAscending = browser.sortAscending
            updatingSelection = true
            if let key = browser.sortKey {
                table.sortDescriptors = [NSSortDescriptor(key: key, ascending: browser.sortAscending)]
            } else {
                table.sortDescriptors = []
            }
            updatingSelection = false
            updateHeaderState()
        }

        // Selection follows the model.
        let wanted = IndexSet(browser.selection.compactMap { rowIndex[$0] })
        if wanted != table.selectedRowIndexes {
            updatingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            updatingSelection = false
        }

        if browser.revealRequest != lastReveal {
            lastReveal = browser.revealRequest
            if let id = playingID, let r = rowIndex[id] {
                table.scrollRowToVisible(r)
                updatingSelection = true
                table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
                updatingSelection = false
                browser.selection = [id]
            }
        }
    }

    private func updateHeaderState() {
        guard let table else { return }
        let key = table.sortDescriptors.first?.key
        let asc = table.sortDescriptors.first?.ascending ?? true
        for col in table.tableColumns {
            guard let cell = col.headerCell as? ITHeaderCell else { continue }
            let colKey = col.sortDescriptorPrototype?.key
            cell.sortState = (key != nil && colKey == key) ? (asc ? 1 : 2) : 0
        }
        table.headerView?.needsDisplay = true
    }

    private func playingChanged(_ id: String?) {
        let old = playingID.flatMap { rowIndex[$0] }
        playingID = id
        let new = id.flatMap { rowIndex[$0] }
        reloadColumn("playing", rows: [old, new].compactMap { $0 })
    }

    private func playingRows() -> [Int] {
        playingID.flatMap { rowIndex[$0] }.map { [$0] } ?? []
    }

    private func reloadColumn(_ id: String, rows: [Int]) {
        guard let table, !rows.isEmpty else { return }
        let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
        guard col >= 0 else { return }
        let valid = rows.filter { $0 >= 0 && $0 < table.numberOfRows }
        table.reloadData(forRowIndexes: IndexSet(valid), columnIndexes: IndexSet(integer: col))
    }

    private func reloadColumns(_ ids: [String], rows: IndexSet) {
        guard let table else { return }
        let cols = IndexSet(ids.map { table.column(withIdentifier: NSUserInterfaceItemIdentifier($0)) }.filter { $0 >= 0 })
        let valid = IndexSet(rows.filter { $0 < table.numberOfRows })
        table.reloadData(forRowIndexes: valid, columnIndexes: cols)
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ITRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let t = rows[row]
        let checked = library.isChecked(t.id)
        let selected = tableView.isRowSelected(row)
        let id = tableColumn.identifier.rawValue

        switch id {
        case "check":
            let cell = checkCell(tableView)
            if let box = cell.subviews.first as? NSButton {
                box.state = checked ? .on : .off
                box.tag = row
            }
            return cell
        case "playing":
            let cell = imageCell(tableView)
            let isCurrent = t.id == playingID
            let symbol = player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill"
            cell.imageView?.image = isCurrent ? NSImage(systemSymbolName: symbol, accessibilityDescription: "Playing") : nil
            cell.imageView?.contentTintColor = selected ? .white : ITStyle.selectionActive
            return cell
        case "rating":
            let cell = ratingCell(tableView)
            if let v = cell.subviews.first as? RatingView {
                v.rating = t.rating
                v.showDots = selected
                v.selected = selected
                v.onSet = { [weak self] stars in self?.setRating(stars, row: row) }
                v.needsDisplay = true
            }
            return cell
        case "artist", "album":
            let cell = linkCell(tableView, id: id)
            cell.textField?.font = ITStyle.font((tableView as? ITTableView)?.textSize ?? .standard)
            cell.textField?.stringValue = id == "artist" ? t.artist : t.album
            cell.textField?.textColor = checked ? ITStyle.text : ITStyle.dimText
            if let link = cell.subviews.compactMap({ $0 as? NSButton }).first {
                let text = id == "artist" ? t.artist : t.album
                link.isHidden = !selected || text.isEmpty
                link.image = ITStyle.arrowImage(selected: selected)
                link.tag = row
                link.identifier = NSUserInterfaceItemIdentifier(id)
            }
            return cell
        default:
            let cell = makeTextCell(tableView, id: id)
            cell.textField?.font = ITStyle.font((tableView as? ITTableView)?.textSize ?? .standard)
            cell.textField?.stringValue = text(for: id, t)
            cell.textField?.alignment = SongColumn.all.first { $0.id == id }?.alignment ?? .left
            cell.textField?.textColor = checked ? ITStyle.text : ITStyle.dimText
            return cell
        }
    }

    private func text(for column: String, _ t: Track) -> String {
        switch column {
        case "name": return t.title
        case "time": return Format.duration(t.duration)
        case "show": return t.podcastShow ?? ""
        case "albumArtist": return t.albumArtist
        case "track": return t.trackNumber > 0 ? "\(t.trackNumber)" : ""
        case "genre": return t.genre
        case "plays": return t.playCount > 0 ? "\(t.playCount)" : ""
        case "lastPlayed": return t.lastPlayed > 0 ? Self.dateFormatter.string(from: Date(timeIntervalSince1970: t.lastPlayed)) : ""
        case "dateAdded": return t.dateAdded > 0 ? Self.dateFormatter.string(from: Date(timeIntervalSince1970: t.dateAdded)) : ""
        case "year": return t.year > 0 ? String(t.year) : ""
        case "kind": return t.kind
        case "bitrate": return t.bitrate > 0 ? "\(t.bitrate) kbps" : ""
        case "size": return Format.bytes(t.size)
        default: return ""
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "artist" { return rows[row].artist }
        return tableColumn?.identifier.rawValue == "name" ? rows[row].title : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table, let browser else { return }
        // Arrows and rating dots follow the selection.
        let visible = table.rows(in: table.visibleRect)
        reloadColumns(["artist", "album", "rating", "playing"],
                      rows: IndexSet(integersIn: visible.location..<(visible.location + visible.length)))
        guard !updatingSelection else { return }
        browser.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        updateHeaderState()
        guard !updatingSelection, let browser else { return }
        let d = tableView.sortDescriptors.first
        lastSortKey = .some(d?.key)
        lastSortAscending = d?.ascending ?? true
        browser.sortAscending = d?.ascending ?? true
        browser.sortKey = d?.key
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows.indices.contains(row) ? rows[row].id as NSString : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard browser?.canReorder == true else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let pl = browser?.currentPlaylist,
              let ids = info.draggingPasteboard.readObjects(forClasses: [NSString.self]) as? [String] else { return false }
        let known = ids.filter { library.track($0) != nil }
        guard !known.isEmpty else { return false }
        // Rows above the drop point shift the playlist index when moved.
        library.place(known, at: row, in: pl.id)
        return true
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0 else { return }
        play(fromRow: table.clickedRow)
    }

    private func play(fromRow row: Int) {
        guard let browser, rows.indices.contains(row) else { return }
        if browser.source == .partyShuffle {
            PartyShuffle.shared.play(at: row)
        } else {
            player.play(queue: rows.map(\.id), startAt: row)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let table else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case 49 where mods.isEmpty:           // space
            if player.current == nil, let r = table.selectedRowIndexes.first { play(fromRow: r) } else { player.togglePlayPause() }
            return true
        case 36, 76:                           // return / enter
            if let r = table.selectedRowIndexes.first { play(fromRow: r) }
            return true
        case 51, 117:                          // delete
            removeSelection()
            return true
        default:
            return false
        }
    }

    private var selectedIDs: [String] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
    }

    private func removeSelection() {
        guard let browser else { return }
        let ids = Set(selectedIDs)
        guard !ids.isEmpty else { return }
        if let pl = browser.currentPlaylist {
            library.remove(ids: ids, from: pl.id)
        } else if browser.source == .partyShuffle {
            PartyShuffle.shared.remove(ids)
        } else if browser.source == .podcasts {
            trashEpisodes(ids)
        } else {
            NSSound.beep()
        }
    }

    private func trashEpisodes(_ ids: Set<String>) {
        guard let window = table?.window, let root = library.libraryRoot else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Delete Episode?" : "Delete \(ids.count) Episodes?"
        alert.informativeText = "The selected episodes will be removed from your library and moved to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, self.library.libraryRoot == root else { return }
            let result = self.library.trashPodcastEpisodes(ids)
            if let current = self.player.current, result.removed.contains(current.id) {
                self.player.stop()
            }
            if let browser = self.browser, browser.source == .podcasts {
                browser.selection.subtract(result.removed)
                if let show = browser.album, !self.library.tracks.contains(where: { $0.podcastShow == show }) {
                    browser.album = nil
                }
            }
            if !result.failures.isEmpty {
                let error = NSAlert()
                error.messageText = "Some files could not be moved to the Trash"
                error.informativeText = result.failures.joined(separator: "\n")
                error.beginSheetModal(for: window)
            }
        }
    }

    @objc func checkToggled(_ sender: NSButton) {
        let row = sender.tag
        guard rows.indices.contains(row), let table else { return }
        let on = sender.state == .on
        // Toggling a box inside a multi-selection applies to the whole selection.
        if table.selectedRowIndexes.contains(row) && table.selectedRowIndexes.count > 1 {
            library.setChecked(selectedIDs, on)
        } else {
            library.setChecked([rows[row].id], on)
        }
    }

    @objc func linkClicked(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), let browser else { return }
        let t = rows[sender.tag]
        if sender.identifier?.rawValue == "album" { browser.showAlbum(of: t) } else { browser.showArtist(of: t) }
    }

    private func setRating(_ stars: Int, row: Int) {
        guard rows.indices.contains(row), let table else { return }
        if table.selectedRowIndexes.contains(row) && table.selectedRowIndexes.count > 1 {
            library.setRating(selectedIDs, stars)
        } else {
            library.setRating([rows[row].id], stars)
        }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === headerMenu {
            buildHeaderMenu(menu)
        } else {
            buildRowMenu(menu)
        }
    }

    private func buildHeaderMenu(_ menu: NSMenu) {
        guard let table, let browser else { return }
        menu.addItem(ClosureMenuItem(browser.isListSource ? "Playlist Order" : "Default Order",
                                     state: browser.sortKey == nil ? .on : .off) { [weak browser] in
            browser?.sortKey = nil
        })
        menu.addItem(.separator())
        let columns = browser.source == .podcasts ? SongColumn.podcasts : SongColumn.all
        for col in table.tableColumns {
            let spec = columns.first { $0.id == col.identifier.rawValue }
            guard let spec, !spec.title.isEmpty, spec.id != "name" else { continue }
            menu.addItem(ClosureMenuItem(spec.title, state: col.isHidden ? .off : .on) { [weak col] in
                col?.isHidden.toggle()
            })
        }
    }

    private func buildRowMenu(_ menu: NSMenu) {
        guard let browser else { return }
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let lib = library

        menu.addItem(ClosureMenuItem("Play") { [weak self] in
            if let r = self?.table?.selectedRowIndexes.first { self?.play(fromRow: r) }
        })
        menu.addItem(ClosureMenuItem("Get Info") { GetInfoController.shared.show(ids: ids) })
        if browser.source != .podcasts, let t = lib.track(ids[0]) {
            let infoItem = NSMenuItem(title: "Get Info for All Songs…", action: nil, keyEquivalent: "")
            let infoMenu = NSMenu()
            func group(_ title: String, _ match: @escaping (Track) -> Bool) {
                let all = lib.tracks.filter(match).map(\.id)
                guard !all.isEmpty else { return }
                infoMenu.addItem(ClosureMenuItem("\(title) (\(all.count))") { GetInfoController.shared.show(ids: all) })
            }
            let artist = t.displayAlbumArtist
            if !t.album.isEmpty { group("On “\(t.album)”", { $0.album == t.album && $0.displayAlbumArtist == artist }) }
            if !artist.isEmpty { group("By “\(artist)”", { $0.displayAlbumArtist == artist }) }
            if !t.genre.isEmpty { group("In Genre “\(t.genre)”", { $0.genre == t.genre }) }
            if infoMenu.numberOfItems > 0 {
                infoItem.submenu = infoMenu
                menu.addItem(infoItem)
            }
        }
        menu.addItem(.separator())

        let ratingItem = NSMenuItem(title: "My Rating", action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu()
        let current = ids.count == 1 ? lib.track(ids[0])?.rating ?? 0 : -1
        for stars in (0...5).reversed() {
            let title = stars == 0 ? "None" : String(repeating: "★", count: stars)
            ratingMenu.addItem(ClosureMenuItem(title, state: current == stars ? .on : .off) { lib.setRating(ids, stars) })
        }
        ratingItem.submenu = ratingMenu
        menu.addItem(ratingItem)
        menu.addItem(ClosureMenuItem("Check Selection") { lib.setChecked(ids, true) })
        menu.addItem(ClosureMenuItem("Uncheck Selection") { lib.setChecked(ids, false) })
        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        let addMenu = NSMenu()
        addMenu.addItem(ClosureMenuItem("New Playlist from Selection") { [weak browser] in
            let id = lib.createPlaylist(name: "untitled playlist", trackIDs: ids)
            browser?.source = .playlist(id)
        })
        let editable = lib.playlists.filter { !$0.isImported }
        if !editable.isEmpty { addMenu.addItem(.separator()) }
        for pl in editable {
            addMenu.addItem(ClosureMenuItem(pl.name) { lib.add(ids, to: pl.id) })
        }
        addItem.submenu = addMenu
        menu.addItem(addItem)

        if let pl = browser.currentPlaylist {
            menu.addItem(ClosureMenuItem("Remove from Playlist") { lib.remove(ids: Set(ids), from: pl.id) })
        } else if browser.source == .partyShuffle {
            menu.addItem(ClosureMenuItem("Remove from Party Shuffle") { PartyShuffle.shared.remove(Set(ids)) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(ids.compactMap { lib.url(forID: $0) })
        })
        menu.addItem(ClosureMenuItem("Reset Play Count") { lib.resetPlayCount(ids) })
        if browser.source == .podcasts {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(ids.count == 1 ? "Delete Episode…" : "Delete Episodes…") { [weak self] in
                self?.trashEpisodes(Set(ids))
            })
        }
    }

    // MARK: Cells

    private func checkCell(_ table: NSTableView) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier("cell.check")
        if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
        let cell = NSTableCellView()
        cell.identifier = ident
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
        box.controlSize = .small
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func imageCell(_ table: NSTableView) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier("cell.image")
        if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
        let cell = NSTableCellView()
        cell.identifier = ident
        let iv = NSImageView()
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        iv.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv)
        cell.imageView = iv
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func ratingCell(_ table: NSTableView) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier("cell.rating")
        if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
        let cell = NSTableCellView()
        cell.identifier = ident
        let rv = RatingView()
        rv.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rv)
        NSLayoutConstraint.activate([
            rv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            rv.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            rv.topAnchor.constraint(equalTo: cell.topAnchor),
            rv.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
        ])
        return cell
    }

    private func linkCell(_ table: NSTableView, id: String) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier("cell.link." + id)
        if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
        let cell = NSTableCellView()
        cell.identifier = ident
        let tf = NSTextField(labelWithString: "")
        tf.font = ITStyle.font()
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let link = NSButton(image: ITStyle.arrowImage(selected: false), target: self, action: #selector(linkClicked(_:)))
        link.isBordered = false
        link.imagePosition = .imageOnly
        link.translatesAutoresizingMaskIntoConstraints = false
        link.toolTip = id == "artist" ? "Show this artist" : "Show this album"
        cell.addSubview(tf)
        cell.addSubview(link)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            link.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 3),
            link.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            link.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            link.widthAnchor.constraint(equalToConstant: 11),
            link.heightAnchor.constraint(equalToConstant: 11)
        ])
        return cell
    }
}

/// My Rating: five stars; empty slots show as dots on the selected row; click to rate,
/// click left of the first star to clear.
final class RatingView: NSView {
    var rating = 0
    var showDots = false
    var selected = false
    var onSet: ((Int) -> Void)?

    private let step: CGFloat = 11

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = selected ? .white : NSColor(white: 0.15, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: color]
        let y = (bounds.height - 13) / 2
        for i in 0..<5 {
            let x = CGFloat(i) * step
            if i < rating {
                ("★" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            } else if showDots {
                color.withAlphaComponent(0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 3.5, y: bounds.midY - 1, width: 2, height: 2)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let stars = x < 2 ? 0 : min(5, Int(x / step) + 1)
        onSet?(stars == rating && stars == 1 ? 0 : stars)
    }
}

/// iTunes-style Genre | Artist | Album browser above the song list.
@MainActor
struct ColumnBrowser: View {
    @ObservedObject var browser: BrowserModel
    /// Called after a double-click has selected the item; plays what the song list now shows.
    var onPlay: () -> Void = {}

    var body: some View {
        PersistentSplit(autosaveName: "iSyncer.ColumnBrowser", panes: [
            .init(view: AnyView(
                ITColumnList(title: "Genre", allLabel: "All", items: browser.genres.map { ITListItem(id: $0, label: $0) },
                             selection: $browser.genreSel, onDoubleClick: onPlay,
                             menu: { menu("Genre", $0) })),
                  minWidth: 100, initialWidth: 220, holding: 255),
            .init(view: AnyView(
                ITColumnList(title: "Artist", allLabel: "All", items: browser.artists.map { ITListItem(id: $0, label: $0) },
                             selection: $browser.artistSel, onDoubleClick: onPlay,
                             menu: { menu("Artist", $0) })),
                  minWidth: 100, initialWidth: 280, holding: 254),
            .init(view: browser.showAlbumArtwork
                  ? AnyView(AlbumArtworkPane(browser: browser, onPlay: onPlay))
                  : AnyView(ITColumnList(title: "Album", allLabel: "All", items: browser.albums.map { ITListItem(id: $0, label: $0) },
                                         selection: $browser.albumSel, onDoubleClick: onPlay,
                                         menu: { menu("Album", $0) })),
                  minWidth: 120, holding: 250)
        ])
    }

    /// Right-click on genres/artists/albums: edit or play every song under them at once.
    private func menu(_ column: String, _ values: Set<String>) -> NSMenu? {
        guard !values.isEmpty else { return nil }
        let ids = browser.trackIDs(column: column, values: values)
        guard !ids.isEmpty else { return nil }
        let lib = LibraryStore.shared
        let what = values.count == 1 ? "“\(values.first!)”" : "\(values.count) \(column == "Genre" ? "Genres" : column + "s")"
        let m = NSMenu()
        let play = onPlay
        m.addItem(ClosureMenuItem("Play \(what)") { play() })
        m.addItem(ClosureMenuItem("Get Info for \(what) (\(ids.count) songs)…") {
            GetInfoController.shared.show(ids: ids)
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Check All") { lib.setChecked(ids, true) })
        m.addItem(ClosureMenuItem("Uncheck All") { lib.setChecked(ids, false) })
        m.addItem(ClosureMenuItem("New Playlist from \(what)") {
            _ = lib.createPlaylist(name: values.count == 1 ? values.first! : "untitled playlist", trackIDs: ids)
        })
        if values.count == 1 {
            m.addItem(.separator())
            let hint = NSMenuItem(title: "Tip: Cmd-click to pick several, then Get Info to fix them together", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            m.addItem(hint)
        }
        return m
    }
}
