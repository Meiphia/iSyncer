import AppKit
import SwiftUI

/// Mid-2000s list styling shared by the song list, the column browser and the video lists:
/// blue-white stripes, a flat blue selection, glossy grey headers (blue on the sorted column),
/// 11 pt Lucida Grande.
enum ITStyle {
    static let font: NSFont = NSFont(name: "LucidaGrande", size: 11) ?? .systemFont(ofSize: 11)
    static let boldFont: NSFont = NSFont(name: "LucidaGrande-Bold", size: 11) ?? .boldSystemFont(ofSize: 11)
    static let smallFont: NSFont = NSFont(name: "LucidaGrande", size: 10) ?? .systemFont(ofSize: 10)

    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let stripe = rgb(0xEDF3FE)
    static let selectionActive = rgb(0x3D80DF)
    static let selectionInactive = rgb(0xCACACA)
    static let grid = rgb(0xD9D9D9)
    // Semantic colours, so selected (blue) rows flip to white text automatically.
    static let text = NSColor.labelColor
    static let dimText = NSColor.secondaryLabelColor
    static let rowHeight: CGFloat = 16

    // Header gradients: glossy Aqua grey, and blue for the sorted column.
    static let headerGrey = NSGradient(colorsAndLocations:
        (rgb(0xFEFEFE), 0), (rgb(0xF1F1F1), 0.5), (rgb(0xE3E3E3), 0.5), (rgb(0xEEEEEE), 1))!
    static let headerBlue = NSGradient(colorsAndLocations:
        (rgb(0xDCE9FB), 0), (rgb(0xB9D2F4), 0.5), (rgb(0x9DC0EE), 0.5), (rgb(0xB8D3F6), 1))!
    static let headerLine = rgb(0x8E8E8E)
    static let headerSeparator = rgb(0xB9B9B9)

    /// Little grey ➜ circle used for the artist/album links.
    static func arrowImage(selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 11, height: 11), flipped: false) { r in
            (selected ? NSColor.white : rgb(0xA6A6A6)).setFill()
            NSBezierPath(ovalIn: r).fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 3, y: 5.5))
            arrow.line(to: NSPoint(x: 7.5, y: 5.5))
            arrow.move(to: NSPoint(x: 5.5, y: 3.2))
            arrow.line(to: NSPoint(x: 7.8, y: 5.5))
            arrow.line(to: NSPoint(x: 5.5, y: 7.8))
            arrow.lineWidth = 1.4
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            (selected ? selectionActive : NSColor.white).setStroke()
            arrow.stroke()
            return true
        }
    }
}

/// Table with the striped background drawn all the way down, even below the last row.
final class ITTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    override func drawBackground(inClipRect clipRect: NSRect) {
        NSColor.white.setFill()
        clipRect.fill()
        let h = rowHeight + intercellSpacing.height
        guard h > 0 else { return }
        var row = Int(floor(clipRect.minY / h))
        var y = CGFloat(row) * h
        ITStyle.stripe.setFill()
        while y < clipRect.maxY {
            if row % 2 == 1 {
                NSRect(x: clipRect.minX, y: y, width: clipRect.width, height: h).fill()
            }
            row += 1
            y += h
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Right-clicking an unselected row selects it first, like iTunes.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

final class ITRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent: the table draws the stripes.
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? ITStyle.selectionActive : ITStyle.selectionInactive).setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

/// Glossy header cell; `sortState` 0 = unsorted, 1 = ascending, 2 = descending.
final class ITHeaderCell: NSTableHeaderCell {
    var sortState = 0

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        (sortState == 0 ? ITStyle.headerGrey : ITStyle.headerBlue).draw(in: cellFrame, angle: 90)
        // Header views are flipped, so 90° puts the gradient's first (light) colour on top.
        ITStyle.headerSeparator.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 2, width: 1, height: cellFrame.height - 4).fill()
        ITStyle.headerLine.setFill()
        NSRect(x: cellFrame.minX, y: controlView.isFlipped ? cellFrame.maxY - 1 : cellFrame.minY,
               width: cellFrame.width, height: 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [.font: ITStyle.font, .foregroundColor: NSColor.black, .paragraphStyle: para]
        let reserve: CGFloat = sortState == 0 ? 0 : 12
        let textRect = NSRect(x: cellFrame.minX + 5, y: cellFrame.minY + (cellFrame.height - 14) / 2,
                              width: max(0, cellFrame.width - 10 - reserve), height: 14)
        (stringValue as NSString).draw(in: textRect, withAttributes: attrs)

        if sortState != 0 {
            let cx = cellFrame.maxX - 10
            let cy = cellFrame.midY
            let tri = NSBezierPath()
            let up = sortState == 1
            // In a flipped view a smaller y is higher on screen.
            let s: CGFloat = controlView.isFlipped ? 1 : -1
            let baseY = up ? cy + 2 * s : cy - 2 * s
            let apexY = up ? cy - 2.5 * s : cy + 2.5 * s
            tri.move(to: NSPoint(x: cx - 3.5, y: baseY))
            tri.line(to: NSPoint(x: cx + 3.5, y: baseY))
            tri.line(to: NSPoint(x: cx, y: apexY))
            tri.close()
            NSColor(white: 0.25, alpha: 1).setFill()
            tri.fill()
        }
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        // Drawn in drawInterior.
    }
}

final class ITHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        // Fill the strip past the last column too.
        ITStyle.headerGrey.draw(in: bounds, angle: 90)
        ITStyle.headerLine.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, key: String = "", state: NSControl.StateValue = .off, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.handler = handler
        self.target = self
        self.state = state
    }

    @objc private func fire() { handler() }
}

func makeHeaderCell(_ title: String) -> ITHeaderCell {
    let cell = ITHeaderCell(textCell: title)
    cell.font = ITStyle.font
    return cell
}

func configureITTable(_ table: NSTableView, header: Bool = true) {
    table.rowHeight = ITStyle.rowHeight
    table.intercellSpacing = NSSize(width: 3, height: 0)
    table.backgroundColor = .white
    table.usesAlternatingRowBackgroundColors = false
    table.gridStyleMask = .solidVerticalGridLineMask
    table.gridColor = ITStyle.grid
    table.selectionHighlightStyle = .regular
    table.focusRingType = .none
    table.style = .plain
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    if header {
        let hv = ITHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 17))
        table.headerView = hv
    } else {
        table.headerView = nil
    }
}

/// A plain text cell with Lucida Grande, created once per identifier and reused.
func makeTextCell(_ table: NSTableView, id: String) -> NSTableCellView {
    let ident = NSUserInterfaceItemIdentifier("text." + id)
    if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
    let cell = NSTableCellView()
    cell.identifier = ident
    let tf = NSTextField(labelWithString: "")
    tf.font = ITStyle.font
    tf.lineBreakMode = .byTruncatingTail
    tf.cell?.truncatesLastVisibleLine = true
    tf.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(tf)
    cell.textField = tf
    NSLayoutConstraint.activate([
        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
}

// MARK: - Single-column list (column browser panes)

struct ITListItem: Hashable {
    let id: String
    let label: String
}

/// One pane of a column browser: glossy header, "All (N)" first row, stripes, double-click.
struct ITColumnList: NSViewRepresentable {
    let title: String
    let allLabel: String
    let items: [ITListItem]
    /// Selected item ids; empty = the "All" row.
    @Binding var selection: Set<String>
    var onDoubleClick: (() -> Void)?
    /// Right-click menu for the selected items (empty set = All).
    var menu: ((Set<String>) -> NSMenu?)?

    static let allID = "\u{0}all"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ITTableView()
        configureITTable(table)
        table.gridStyleMask = []
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.headerCell = makeHeaderCell(title)
        col.headerCell.alignment = .center
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let m = NSMenu()
        m.delegate = context.coordinator
        table.menu = m
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }
        (table.tableColumns.first?.headerCell as? ITHeaderCell)?.stringValue = title
        let rows = [ITListItem(id: Self.allID, label: "\(allLabel) (\(items.count.formatted()))")] + items
        if rows != c.rows {
            c.rows = rows
            table.reloadData()
        }
        var want = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
        if want.isEmpty { want = IndexSet(integer: 0) }
        if table.selectedRowIndexes != want {
            c.updating = true
            table.selectRowIndexes(want, byExtendingSelection: false)
            if let first = want.first { table.scrollRowToVisible(first) }
            c.updating = false
        }
        table.headerView?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ITColumnList?
        var rows: [ITListItem] = []
        weak var table: NSTableView?
        var updating = false

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = makeTextCell(tableView, id: "list")
            cell.textField?.stringValue = rows[row].label
            cell.textField?.font = row == 0 ? ITStyle.boldFont : ITStyle.font
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ITRowView() }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            row == 0 ? nil : rows[row].label
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, let parent else { return }
            let picked = table.selectedRowIndexes.filter { rows.indices.contains($0) }
            let others = Set(picked.filter { $0 != 0 }.map { rows[$0].id })
            var next: Set<String>
            if picked.contains(0) && !others.isEmpty {
                // All plus items: adding to "All" picks the items; clicking All clears them.
                next = parent.selection.isEmpty ? others : []
            } else {
                next = others
            }
            if next != parent.selection { parent.selection = next }
            if picked.contains(0) && !others.isEmpty {
                updating = true
                let idx = next.isEmpty ? IndexSet(integer: 0)
                                       : IndexSet(rows.indices.filter { next.contains(rows[$0].id) })
                table.selectRowIndexes(idx, byExtendingSelection: false)
                updating = false
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let parent, let built = parent.menu?(parent.selection) else { return }
            for item in built.items {
                built.removeItem(item)
                menu.addItem(item)
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            parent?.onDoubleClick?()
        }
    }
}

// MARK: - Persistent split view

/// Side-by-side panes in an NSSplitView whose divider positions are saved (autosaveName), so
/// pane widths survive switching sources and relaunching. SwiftUI's HSplitView forgets them
/// whenever its content is rebuilt.
struct PersistentSplit: NSViewRepresentable {
    struct Pane {
        let view: AnyView
        var minWidth: CGFloat = 80
        var maxWidth: CGFloat = .greatestFiniteMagnitude
        /// Width used the very first time (before anything is saved).
        var initialWidth: CGFloat?
        /// Higher keeps its width when the window resizes.
        var holding: Float = 250
    }

    let autosaveName: String
    let panes: [Pane]

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Applies first-run widths once the split has a real size.
    final class SplitView: NSSplitView {
        var pendingWidths: [CGFloat]?
        override func layout() {
            super.layout()
            guard let widths = pendingWidths, bounds.width > 0 else { return }
            pendingWidths = nil
            var x: CGFloat = 0
            for (i, w) in widths.enumerated() {
                x += w
                setPosition(x, ofDividerAt: i)
                x += dividerThickness
            }
        }
    }

    func makeNSView(context: Context) -> NSSplitView {
        let split = SplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        context.coordinator.panes = panes
        for (i, p) in panes.enumerated() {
            let host = NSHostingView(rootView: p.view)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            split.addArrangedSubview(host)
            split.setHoldingPriority(NSLayoutConstraint.Priority(p.holding), forSubviewAt: i)
        }
        let key = "NSSplitView Subview Frames \(autosaveName)"
        let hasSaved = UserDefaults.standard.object(forKey: key) != nil
        split.autosaveName = autosaveName
        if !hasSaved {
            split.pendingWidths = panes.dropLast().map { $0.initialWidth ?? 200 }
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.panes = panes
        for (i, p) in panes.enumerated() where i < split.arrangedSubviews.count {
            (split.arrangedSubviews[i] as? NSHostingView<AnyView>)?.rootView = p.view
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var panes: [Pane] = []

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard panes.indices.contains(dividerIndex), dividerIndex < splitView.arrangedSubviews.count else { return proposedMinimumPosition }
            let left = splitView.arrangedSubviews[dividerIndex].frame
            var minPos = left.minX + panes[dividerIndex].minWidth
            if dividerIndex + 1 < panes.count, dividerIndex + 1 < splitView.arrangedSubviews.count {
                let right = splitView.arrangedSubviews[dividerIndex + 1].frame
                let maxRight = panes[dividerIndex + 1].maxWidth
                if maxRight < .greatestFiniteMagnitude { minPos = max(minPos, right.maxX - maxRight - splitView.dividerThickness) }
            }
            return max(proposedMinimumPosition, minPos)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex + 1 < panes.count, dividerIndex + 1 < splitView.arrangedSubviews.count else { return proposedMaximumPosition }
            let left = splitView.arrangedSubviews[dividerIndex].frame
            let right = splitView.arrangedSubviews[dividerIndex + 1].frame
            var maxPos = right.maxX - panes[dividerIndex + 1].minWidth - splitView.dividerThickness
            let maxLeft = panes[dividerIndex].maxWidth
            if maxLeft < .greatestFiniteMagnitude { maxPos = min(maxPos, left.minX + maxLeft) }
            return min(proposedMaximumPosition, maxPos)
        }
    }
}
