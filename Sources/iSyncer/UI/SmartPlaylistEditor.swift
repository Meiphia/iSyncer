import SwiftUI
import AppKit

/// The iTunes-style smart playlist editor, in its own window.
@MainActor
final class SmartPlaylistEditor: NSObject, NSWindowDelegate {
    static let shared = SmartPlaylistEditor()
    private var window: NSWindow?

    /// Opens the editor for a new playlist (`list` nil) or an existing one.
    func open(_ list: SmartPlaylist? = nil, onSave: ((UUID) -> Void)? = nil) {
        window?.close()
        let isNew = list == nil
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = isNew ? "New Smart Playlist" : "Edit “\(list!.name)”"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.delegate = self
        w.contentView = NSHostingView(rootView: SmartPlaylistForm(list: list ?? SmartPlaylist(), isNew: isNew) { [weak w] saved in
            if let saved {
                LibraryStore.shared.saveSmartList(saved)
                onSave?(saved.id)
            }
            w?.close()
        })
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { window = nil }
    }
}

@MainActor
private struct SmartPlaylistForm: View {
    @State var list: SmartPlaylist
    let isNew: Bool
    let done: (SmartPlaylist?) -> Void
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Name:")
                TextField("", text: $list.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 4) {
                Text("Match")
                Picker("", selection: $list.matchAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following rules:")
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($list.rules) { $rule in
                        RuleRow(rule: $rule,
                                canRemove: list.rules.count > 1,
                                remove: { list.rules.removeAll { $0.id == rule.id } },
                                add: {
                                    let i = (list.rules.firstIndex { $0.id == rule.id } ?? list.rules.count - 1) + 1
                                    list.rules.insert(SmartRule(), at: i)
                                })
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.35)))

            HStack(spacing: 6) {
                Toggle("Limit to", isOn: $list.limitEnabled)
                TextField("", value: $list.limitCount, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Picker("", selection: $list.limitUnit) {
                    ForEach(SmartPlaylist.LimitUnit.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text("selected by")
                Picker("", selection: $list.selectedBy) {
                    ForEach(SmartPlaylist.SelectedBy.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .disabled(false)
            Toggle("Match only checked songs", isOn: $list.onlyChecked)
            Toggle("Live updating", isOn: .constant(true)).disabled(true)

            HStack {
                Text(matchSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    var saved = list
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces).isEmpty ? "untitled smart playlist" : saved.name
                    saved.seed = UInt64.random(in: 0...UInt64.max)   // a fresh random pick, like iTunes
                    done(saved)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(16)
        .frame(minWidth: 640, minHeight: 340)
        .preferredColorScheme(.light)
    }

    private var matchSummary: String {
        let ids = list.evaluate(library.tracks, unchecked: library.unchecked)
        let seconds = ids.compactMap { library.track($0)?.duration }.reduce(0, +)
        return "\(ids.count.formatted()) songs match · \(Format.duration(seconds))"
    }
}

@MainActor
private struct RuleRow: View {
    @Binding var rule: SmartRule
    let canRemove: Bool
    let remove: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { rule.field }, set: { f in
                let oldKind = rule.field.kind
                rule.field = f
                if f.kind != oldKind {
                    rule.op = SmartRule.Op.options(for: f.kind)[0]
                    rule.number = f.kind == .rating ? 4 : (f.kind == .date ? 2 : 0)
                    rule.number2 = 0
                    rule.unit = .weeks
                }
            })) {
                ForEach(SmartRule.Field.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 120)

            Picker("", selection: Binding(get: { rule.op }, set: { op in
                if rule.field.kind == .date, (op == .before || op == .after), rule.number < 1_000_000 {
                    rule.number = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
                }
                if rule.field.kind == .date, (op == .inLast || op == .notInLast), rule.number > 1_000_000 {
                    rule.number = 2
                }
                rule.op = op
            })) {
                ForEach(SmartRule.Op.options(for: rule.field.kind)) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 150)

            value
            Spacer(minLength: 4)
            Button { remove() } label: { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove this rule")
            Button { add() } label: { Image(systemName: "plus") }
                .help("Add a rule")
        }
    }

    @ViewBuilder
    private var value: some View {
        switch rule.field.kind {
        case .text:
            TextField("", text: $rule.text).textFieldStyle(.roundedBorder)
        case .number:
            HStack(spacing: 4) {
                TextField("", value: $rule.number, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                if rule.op == .inRange {
                    Text("to")
                    TextField("", value: $rule.number2, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                if !rule.field.suffix.isEmpty { Text(rule.field.suffix).foregroundStyle(.secondary) }
            }
        case .rating:
            HStack(spacing: 6) {
                Stars(value: $rule.number)
                if rule.op == .inRange {
                    Text("to")
                    Stars(value: $rule.number2)
                }
            }
        case .date:
            if rule.op == .before || rule.op == .after {
                DatePicker("", selection: Binding(
                    get: { Date(timeIntervalSince1970: rule.number) },
                    set: { rule.number = $0.timeIntervalSince1970 }), displayedComponents: .date)
                    .labelsHidden().fixedSize()
            } else {
                HStack(spacing: 4) {
                    TextField("", value: $rule.number, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                    Picker("", selection: $rule.unit) {
                        ForEach(SmartRule.DateUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
}

private struct Stars: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { s in
                Image(systemName: Double(s) <= value ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .onTapGesture { value = value == Double(s) ? Double(s - 1) : Double(s) }
            }
        }
    }
}
