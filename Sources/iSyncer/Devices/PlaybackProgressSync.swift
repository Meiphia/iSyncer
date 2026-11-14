import ClassicSync
import Foundation

struct PlaybackConflictRequest: Identifiable {
    let id = UUID()
    let device: UUID
    let retry: Set<URL>?
    let changes: [ListeningChange]
}

struct PlaybackProgressSync {
    struct Selection {
        let mac: ClassicListeningState
        let iPod: ClassicListeningState
        let preferIPod: Bool
    }

    let root: URL
    let matches: [ListeningChange]
    let expected: [Data: ClassicListeningState]
    let desired: [Data: ClassicListeningState]
    let imports: [ListeningChange]
    let conflicts: [ListeningChange]

    init(root: URL, matches: [ListeningChange], baseline: [String: ClassicListeningState],
         choices: [String: Selection]) {
        var expected: [Data: ClassicListeningState] = [:]
        var desired: [Data: ClassicListeningState] = [:]
        var imports: [ListeningChange] = []
        var conflicts: [ListeningChange] = []
        for match in matches {
            let mac = match.macState, iPod = match.iPodState
            let key = match.play.id.base64EncodedString()
            expected[match.play.id] = iPod
            var decision = ClassicListeningState.reconcile(mac: mac, iPod: iPod, last: baseline[key])
            if decision == .conflict, let choice = choices[match.id], choice.mac.matches(mac), choice.iPod.matches(iPod) {
                decision = choice.preferIPod ? .useIPod : .useMac
            }
            switch decision {
            case .same:
                if iPod.milliseconds > 0 || iPod.played { desired[match.play.id] = iPod }
            case .useMac: desired[match.play.id] = mac
            case .useIPod:
                desired[match.play.id] = iPod
                imports.append(match)
            case .conflict: conflicts.append(match)
            }
        }
        self.root = root
        self.matches = matches
        self.expected = expected
        self.desired = desired
        self.imports = imports
        self.conflicts = conflicts
    }
}
