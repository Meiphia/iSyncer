import Foundation
import Combine

/// iTunes' Party Shuffle: a few recently played songs, then a rolling list of upcoming random
/// picks from your checked songs. Playing from it keeps the list topped up as songs finish.
@MainActor
final class PartyShuffle: ObservableObject {
    static let shared = PartyShuffle()

    @Published private(set) var list: [String] = []
    @Published var upcomingCount = UserDefaults.standard.object(forKey: "party.upcoming") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(upcomingCount, forKey: "party.upcoming"); topUp() }
    }
    let recentCount = 5

    private var cancellables = Set<AnyCancellable>()
    private var library: LibraryStore { LibraryStore.shared }
    private var player: PlayerEngine { PlayerEngine.shared }

    private init() {
        PlayerEngine.shared.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.songChanged(t) }
            .store(in: &cancellables)
    }

    /// Fresh random list.
    func refresh() {
        list = []
        topUp()
    }

    func ensureFilled() {
        if list.isEmpty { topUp() }
    }

    /// Starts playing the list at a row.
    func play(at index: Int) {
        ensureFilled()
        guard list.indices.contains(index) else { return }
        player.play(queue: list, startAt: index, partyShuffle: true)
    }

    private func songChanged(_ t: Track?) {
        guard player.playingPartyShuffle, let t, let i = list.firstIndex(of: t.id) else { return }
        // Keep a few played songs above the current one, drop older ones.
        if i > recentCount {
            list.removeFirst(i - recentCount)
        }
        topUp()
    }

    private func topUp() {
        let currentIndex = player.playingPartyShuffle
            ? (player.current.flatMap { c in list.firstIndex(of: c.id) } ?? -1)
            : -1
        let have = list.count - (currentIndex + 1)
        let need = upcomingCount - have
        guard need > 0 else { return }
        let pool = library.tracks.filter { library.isChecked($0.id) }.map(\.id)
        guard !pool.isEmpty else { return }
        let recent = Set(list.suffix(50))
        var added: [String] = []
        var attempts = 0
        while added.count < need && attempts < need * 20 {
            attempts += 1
            guard let pick = pool.randomElement() else { break }
            if recent.contains(pick) || added.contains(pick) { continue }
            added.append(pick)
        }
        list.append(contentsOf: added)
        if player.playingPartyShuffle { player.enqueue(added) }
    }

    /// Removing a song from Party Shuffle.
    func remove(_ ids: Set<String>) {
        list.removeAll { ids.contains($0) }
        topUp()
    }
}
