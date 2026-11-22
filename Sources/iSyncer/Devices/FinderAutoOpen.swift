import Foundation

/// Opt-in macOS preference. It affects automatic Apple-device syncing for this user;
/// it does not hide devices, terminate Finder, or stop Apple's background agents.
@MainActor
final class FinderAutoOpen: ObservableObject {
    static let shared = FinderAutoOpen()
    static let systemKey = "dontAutomaticallySyncIPods"
    private static let enabledKey = "preventFinderAutomaticOpen"
    private static let previousKey = "previousFinderAutoSyncPreference"
    private let defaults: UserDefaults
    private let system: UserDefaults
    @Published private(set) var enabled: Bool

    init(defaults: UserDefaults = .standard,
         system: UserDefaults = UserDefaults(suiteName: "com.apple.AMPDevicesAgent")!) {
        self.defaults = defaults
        self.system = system
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ value: Bool) throws {
        guard enabled != value else { return }
        let previous = system.object(forKey: Self.systemKey)
        if value {
            let snapshot: [String: Any] = previous.map { ["value": $0] } ?? [:]
            let encoded = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
            system.set(true, forKey: Self.systemKey)
            guard system.synchronize() else {
                system.set(previous, forKey: Self.systemKey)
                throw ShellError(message: "macOS couldn’t save its automatic device-sync preference.")
            }
            defaults.set(encoded, forKey: Self.previousKey)
        } else {
            // Restore only the preference we changed. Preserve a subsequent external change.
            if system.bool(forKey: Self.systemKey),
               let data = defaults.data(forKey: Self.previousKey),
               let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                system.set(saved["value"], forKey: Self.systemKey)
                guard system.synchronize() else {
                    system.set(previous, forKey: Self.systemKey)
                    throw ShellError(message: "macOS couldn’t restore its automatic device-sync preference.")
                }
            }
            defaults.removeObject(forKey: Self.previousKey)
        }
        defaults.set(value, forKey: Self.enabledKey)
        enabled = value
    }
}
