import AVFoundation
import AppKit
import Combine
import MediaPlayer

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

enum ReplayGainMode: String, CaseIterable, Identifiable {
    case off, track, album, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track gain"
        case .album: return "Album gain"
        case .auto: return "Automatic (album; track when shuffling)"
        }
    }
}

/// Playback on one AVAudioEngine with two "decks" (player nodes) feeding a shared mixer,
/// equalizer and output. The next song is always scheduled ahead on the idle deck, timed to
/// the sample against the current one: exactly at its end (gapless) or a few seconds before
/// it (crossfade). Everything goes through a single audio output, so starting and stopping
/// songs never makes macOS reset the output (which is what causes audible dropouts).
///
/// AVAudioFile reads MP3, AAC, ALAC, FLAC, WAV and AIFF; Ogg/Opus are decoded by ffmpeg into
/// a cached lossless copy first (see PlaybackCache).
@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var message: String?
    @Published var volume: Float {
        didSet {
            engine.mainMixerNode.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    @Published var shuffle = false {
        didSet { rebuildOrder(); disarmNext(); applyReplayGain() }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { disarmNext() }
    }
    /// Sound levelling from ReplayGain values. Auto = album gain, track gain when shuffling.
    @Published var replayGainMode = ReplayGainMode(rawValue: UserDefaults.standard.string(forKey: "rgMode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(replayGainMode.rawValue, forKey: "rgMode"); applyReplayGain() }
    }
    /// Extra dB on top of ReplayGain (songs without values get just this).
    @Published var replayGainPreamp = Float(UserDefaults.standard.double(forKey: "rgPreamp")) {
        didSet { UserDefaults.standard.set(Double(replayGainPreamp), forKey: "rgPreamp"); applyReplayGain() }
    }
    /// True while playing from Party Shuffle (which keeps topping up the queue).
    @Published private(set) var playingPartyShuffle = false

    /// Seconds of crossfade between songs (0 = off). Settings → Playback.
    var crossfadeSeconds: Double { UserDefaults.standard.double(forKey: "crossfade") }
    /// Don't crossfade between consecutive songs of the same album (keeps live albums seamless).
    var crossfadeKeepsAlbums: Bool { UserDefaults.standard.object(forKey: "crossfadeAlbums") as? Bool ?? true }

    // MARK: Audio graph

    private final class Deck {
        let node = AVAudioPlayerNode()
        /// Per-song gain (ReplayGain), as an EQ unit with no bands: globalGain goes up to +24 dB.
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        var format: AVAudioFormat?
        var file: AVAudioFile?
        var trackID: String?
        var orderPosition = -1
        /// First frame of the scheduled segment (non-zero after a seek).
        var startFrame: AVAudioFramePosition = 0
        var frameCount: AVAudioFrameCount = 0
        /// Bumped whenever the deck is stopped or rescheduled, so stale completions are ignored.
        var token = 0
        var sampleRate: Double { format?.sampleRate ?? 44100 }
        var seconds: Double { Double(frameCount) / sampleRate }
    }

    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let decks = [Deck(), Deck()]
    private var cur = 0
    private var other: Int { 1 - cur }
    /// The idle deck holds the next song, scheduled to start at the right moment.
    private var armed = false
    /// While crossfading: the deck fading out, and the fade length.
    private var fadingOut: (deck: Int, length: Double)?
    private var ticker: Timer?
    private var tickCount = 0

    private let library = LibraryStore.shared
    private var queue: [String] = []        // track IDs in list order
    private var order: [Int] = []           // play order (indices into queue)
    private var position_: Int = 0          // index into order
    private var cancellables = Set<AnyCancellable>()
    private var countedCurrent = false
    /// Seconds of the current song actually heard (seeking ahead doesn't count).
    private var listened: Double = 0
    private var lastTickTime: Double?
    /// How much of a song must be heard before it counts as played and scrobbles:
    /// this share of the song, or 4 minutes, whichever comes first (Last.fm's rule at 50%).
    var playThreshold: Double {
        let v = UserDefaults.standard.object(forKey: "playThreshold") as? Double ?? 0.5
        return min(max(v, 0.1), 0.9)
    }
    private var failures = 0
    /// The song waiting for its Ogg/Opus conversion before it can start.
    private var pendingID: String?
    private var startedAt = Date()

    private init() {
        let saved = UserDefaults.standard.object(forKey: "volume") as? Float
        volume = saved ?? 0.8

        engine.attach(bus)
        engine.attach(eq)
        for d in decks {
            engine.attach(d.node)
            engine.attach(d.gain)
        }
        let out = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(bus, to: eq, format: out)
        engine.connect(eq, to: engine.mainMixerNode, format: out)
        engine.mainMixerNode.outputVolume = volume
        configureEQ()

        // Spectrum feed: the mixed signal after the equalizer.
        eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            AudioProcessor.shared.push(ch[0], count: Int(buffer.frameLength), stride: buffer.stride,
                                       sampleRate: buffer.format.sampleRate)
        }

        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.outputChanged() }
            .store(in: &cancellables)

        EqualizerModel.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureEQ() }
            .store(in: &cancellables)

        applyReplayGain()
        setupRemoteCommands()
    }

    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            message = "Couldn't start audio output: \(error.localizedDescription)"
            return false
        }
    }

    /// The output device changed (headphones, AirPlay…): the engine stops itself; pick up again.
    private func outputChanged() {
        guard current != nil else { return }
        let resumeAt = position
        let wasPlaying = isPlaying
        loadCurrent(from: resumeAt, autoplay: wasPlaying)
    }

    // MARK: Equalizer and ReplayGain

    private func configureEQ() {
        let model = EqualizerModel.shared
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Float(AudioProcessor.bandFrequencies[i])
            band.bandwidth = 1.0
            band.gain = i < model.gains.count ? model.gains[i] : 0
            band.bypass = false
        }
        eq.globalGain = model.enabled ? model.preamp : 0
        eq.bypass = !model.enabled
    }

    private var effectiveGainMode: Int {
        switch replayGainMode {
        case .off: return 0
        case .track: return 1
        case .album: return 2
        case .auto: return shuffle ? 1 : 2
        }
    }

    private func applyReplayGain() {
        for d in decks { d.gain.globalGain = replayGainDB(for: d.trackID.flatMap { library.track($0) }) }
    }

    /// dB for a song in the current mode, limited so its peak can't clip.
    private func replayGainDB(for t: Track?) -> Float {
        let mode = effectiveGainMode
        guard mode != 0, let t else { return mode == 0 ? 0 : replayGainPreamp }
        var db: Double?
        var peak: Double?
        if mode == 2, let a = t.rgAlbumGain { db = a; peak = t.rgAlbumPeak ?? t.rgTrackPeak }
        else { db = t.rgTrackGain ?? t.rgAlbumGain; peak = t.rgTrackPeak ?? t.rgAlbumPeak }
        var total = (db ?? 0) + Double(replayGainPreamp)
        if let peak, peak > 0 { total = min(total, -20 * log10(peak)) }
        return Float(max(-60, min(24, total)))
    }

    // MARK: Public controls

    var hasQueue: Bool { !queue.isEmpty }

    func play(queue ids: [String], startAt index: Int, partyShuffle: Bool = false) {
        guard !ids.isEmpty, ids.indices.contains(index) else { return }
        saveCurrentListening()
        playingPartyShuffle = partyShuffle
        queue = ids
        if partyShuffle {
            // Party Shuffle is already random; play it in list order.
            order = Array(queue.indices)
            position_ = index
        } else {
            rebuildOrder(startingWith: index)
            position_ = order.firstIndex(of: index) ?? 0
        }
        loadCurrent()
    }

    var upcoming: [(offset: Int, id: String)] {
        guard current != nil else { return [] }
        return order.indices.dropFirst(position_ + 1).prefix(50).map { ($0, queue[order[$0]]) }
    }

    func playUpcoming(at offset: Int, id: String) {
        guard offset > position_, order.indices.contains(offset), queue[order[offset]] == id else { return }
        saveCurrentListening()
        position_ = offset
        loadCurrent()
    }

    /// Appends songs to the end of the play order (Party Shuffle top-ups).
    func enqueue(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let start = queue.count
        queue.append(contentsOf: ids)
        order.append(contentsOf: start..<queue.count)
        objectWillChange.send()
    }

    func togglePlayPause() {
        guard current != nil else { return }
        if isPlaying {
            saveCurrentListening()
            // The next song is lined up in wall-clock time; drop it (and any fade) and line it
            // up again after resuming.
            disarmNext()
            if let f = fadingOut { halt(decks[f.deck]); fadingOut = nil; decks[cur].node.volume = 1 }
            engine.pause()
            isPlaying = false
        } else if pendingID == nil {
            if decks[cur].file == nil { loadCurrent(from: position); return }
            guard startEngineIfNeeded() else { return }
            if !decks[cur].node.isPlaying { decks[cur].node.play() }
            isPlaying = true
            // Last.fm's "Scrobbling now" expires; refresh it when playback resumes.
            if let c = current { LastFM.shared.nowPlaying(c) }
        }
        updateNowPlaying()
    }

    func stop() {
        saveCurrentListening()
        pendingID = nil
        for d in decks { halt(d) }
        armed = false
        fadingOut = nil
        engine.pause()
        isPlaying = false
        current = nil
        position = 0
        duration = 0
        ticker?.invalidate()
        ticker = nil
        updateNowPlaying()
    }

    func next() {
        guard let p = nextPosition(after: position_, manual: true) else { stop(); return }
        saveCurrentListening()
        position_ = p
        loadCurrent()
    }

    func previous() {
        if position > 3 || order.isEmpty {
            seek(to: 0)
            return
        }
        saveCurrentListening()
        position_ = position_ > 0 ? position_ - 1 : (repeatMode == .all ? order.count - 1 : 0)
        loadCurrent()
    }

    func seek(to seconds: Double) {
        guard current != nil else { return }
        DiscordPresence.shared.refresh()
        loadCurrent(from: max(0, min(seconds, max(duration - 0.05, 0))), autoplay: isPlaying || pendingID != nil)
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: Queue management

    private func rebuildOrder(startingWith start: Int? = nil) {
        guard !queue.isEmpty else { order = []; return }
        let currentIndex = start ?? (order.indices.contains(position_) ? order[position_] : 0)
        if shuffle {
            var rest = Array(queue.indices).filter { $0 != currentIndex }
            rest.shuffle()
            order = [currentIndex] + rest
            position_ = 0
        } else {
            order = Array(queue.indices)
            position_ = currentIndex
        }
    }

    private func nextPosition(after p: Int, manual: Bool = false) -> Int? {
        if repeatMode == .one && !manual { return p }
        if p + 1 < order.count { return p + 1 }
        return repeatMode != .off && !order.isEmpty ? 0 : nil
    }

    // MARK: Decks

    /// The file to play for an order position (nil while an Ogg/Opus is still being decoded).
    private func playableURL(at orderPosition: Int, onReady: @escaping () -> Void) -> URL?? {
        guard order.indices.contains(orderPosition) else { return .some(nil) }
        let id = queue[order[orderPosition]]
        guard let url = library.url(forID: id) else { return .some(nil) }
        guard PlaybackCache.needsConversion(url) else { return .some(url) }
        if let cached = PlaybackCache.shared.cachedURL(for: url) { return .some(cached) }
        PlaybackCache.shared.prepare(url) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                if self.pendingID == id {
                    self.pendingID = nil
                    self.message = error.localizedDescription
                    self.failures += 1
                    if self.failures < 25 { self.next() }
                }
                return
            }
            onReady()
        }
        return nil   // not ready yet
    }

    /// Stops a deck and invalidates its pending completion.
    private func halt(_ d: Deck) {
        d.token += 1
        d.node.stop()
        d.file = nil
        d.trackID = nil
        d.orderPosition = -1
    }

    /// Loads a song onto a deck and schedules it, optionally from a time and at a start time.
    private func load(_ d: Deck, url: URL, orderPosition: Int, from seconds: Double = 0) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        halt(d)
        if d.format != fmt {
            engine.disconnectNodeOutput(d.node)
            engine.disconnectNodeOutput(d.gain)
            engine.connect(d.node, to: d.gain, format: fmt)
            engine.connect(d.gain, to: bus, format: fmt)
            d.format = fmt
        }
        let start = max(0, min(AVAudioFramePosition(seconds * fmt.sampleRate), file.length - 1))
        d.file = file
        d.trackID = queue[order[orderPosition]]
        d.orderPosition = orderPosition
        d.startFrame = start
        d.frameCount = AVAudioFrameCount(max(1, file.length - start))
        d.gain.globalGain = replayGainDB(for: d.trackID.flatMap { library.track($0) })
        let token = d.token
        let deckIndex = decks.firstIndex { $0 === d }
        d.node.scheduleSegment(file, startingFrame: start, frameCount: d.frameCount, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, let deckIndex else { return }
                let deck = self.decks[deckIndex]
                guard deck.token == token else { return }
                self.deckFinished(deck)
            }
        }
    }

    /// Starts the song at `position_` on a fresh deck, right now.
    private func loadCurrent(from requestedPosition: Double? = nil, autoplay: Bool = true) {
        pendingID = nil
        for d in decks { halt(d) }
        armed = false
        fadingOut = nil
        guard order.indices.contains(position_) else { return }
        let id = queue[order[position_]]
        current = library.track(id)
        duration = current?.duration ?? 0
        let bookmark = current?.finishedListening == true ? 0 : current?.resumePosition ?? 0
        let seconds = requestedPosition ?? (bookmark >= max(0, duration - 1) ? 0 : bookmark)
        position = seconds
        message = nil

        guard let urlOpt = playableURL(at: position_, onReady: { [weak self] in
            guard let self, self.pendingID == id else { return }
            self.loadCurrent(from: requestedPosition, autoplay: autoplay)
        }) else {
            pendingID = id
            message = "Decoding for playback…"
            updateNowPlaying()
            return
        }
        guard let url = urlOpt else { failed(); return }

        let d = decks[cur]
        do {
            try load(d, url: url, orderPosition: position_, from: seconds)
        } catch {
            failed()
            return
        }
        for v in decks { v.node.volume = 1 }
        duration = d.seconds + Double(d.startFrame) / d.sampleRate
        if requestedPosition == nil || seconds == 0 {
            songStarted(announce: autoplay)
            position = seconds
        }
        guard autoplay else { isPlaying = false; updateNowPlaying(); return }
        guard startEngineIfNeeded() else { return }
        d.node.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    private func failed() {
        let name = current?.title ?? "song"
        message = "Can't play “\(name)”."
        failures += 1
        if failures < 25 { next() } else { failures = 0; stop() }
    }

    /// Bookkeeping when a song begins (from the start).
    private func songStarted(announce: Bool = true) {
        countedCurrent = false
        listened = 0
        lastTickTime = nil
        startedAt = Date()
        position = 0
        if announce, let c = current { LastFM.shared.nowPlaying(c) }
    }

    /// Schedules the next song on the idle deck so it starts exactly when the current one
    /// ends (or `crossfade` seconds earlier).
    private func armNext() {
        // The idle deck is still fading out the previous song: wait until it's free.
        guard !armed, fadingOut == nil, pendingID == nil, isPlaying else { return }
        let cd = decks[cur]
        guard cd.file != nil, let np = nextPosition(after: position_),
              let rt = cd.node.lastRenderTime, rt.isSampleTimeValid, rt.isHostTimeValid,
              let pt = cd.node.playerTime(forNodeTime: rt) else { return }
        guard current?.isMusic == true, library.track(queue[order[np]])?.isMusic == true else { return }

        guard let urlOpt = playableURL(at: np, onReady: { }) else { return }   // decoding; try again later
        guard let url = urlOpt else { return }

        var fade = repeatMode == .one ? 0 : crossfadeSeconds   // a repeated song loops seamlessly
        if fade > 0, crossfadeKeepsAlbums, let a = current, let b = library.track(queue[order[np]]),
           !a.album.isEmpty, a.album == b.album, a.displayAlbumArtist == b.displayAlbumArtist,
           b.discNumber * 1000 + b.trackNumber == a.discNumber * 1000 + a.trackNumber + 1 {
            fade = 0
        }
        let remaining = Double(Int64(cd.frameCount) - pt.sampleTime) / cd.sampleRate
        if fade > 0 { fade = min(fade, remaining / 2, (library.track(queue[order[np]])?.duration ?? 60) / 3) }
        let lead = remaining - fade
        guard lead > 0.25 else { return }   // too close to the end to line up; it'll just follow on

        let nd = decks[other]
        do {
            try load(nd, url: url, orderPosition: np)
        } catch {
            return
        }
        nd.node.volume = fade > 0 ? 0 : 1
        // Host time is shared by both decks (their sample clocks may run at different rates).
        nd.node.play(at: AVAudioTime(hostTime: rt.hostTime + AVAudioTime.hostTime(forSeconds: lead)))
        armed = true
        pendingFade = fade
    }
    private var pendingFade: Double = 0

    private func disarmNext() {
        guard armed else { return }
        halt(decks[other])
        armed = false
    }

    /// A deck reached the end of its song.
    private func deckFinished(_ d: Deck) {
        let isCurrent = d === decks[cur]
        d.file = nil
        d.trackID = nil
        if let f = fadingOut, decks[f.deck] === d { fadingOut = nil; decks[cur].node.volume = 1 }
        guard isCurrent else { return }
        if let current, !current.isMusic { library.saveListening(current.id, position: 0, finished: true) }
        // The current song ended without a next one lined up (end of queue, or not ready in time).
        if armed { return }
        if let np = nextPosition(after: position_) {
            position_ = np
            loadCurrent()
        } else {
            isPlaying = false
            current = nil
            position = 0
            duration = 0
            engine.pause()
            updateNowPlaying()
        }
    }

    /// The armed deck has started: it becomes the current song.
    private func promote() {
        let old = cur
        cur = other
        armed = false
        let d = decks[cur]
        position_ = d.orderPosition
        current = d.trackID.flatMap { library.track($0) }
        duration = d.seconds
        message = nil
        failures = 0
        songStarted()
        if pendingFade > 0 { fadingOut = (old, pendingFade) } else { decks[old].node.volume = 1 }
        updateNowPlaying()
    }

    // MARK: Resume where you left off

    private struct SavedState: Codable {
        var queue: [String]
        var order: [Int]
        var index: Int
        var position: Double
        var shuffle: Bool
        var repeatMode: String
        var partyShuffle: Bool
    }

    private var stateFile: URL { LibraryStore.supportFolder.appendingPathComponent("player.json") }

    /// Remembers the queue, song and position (at quit, and every half minute while playing).
    func saveState() {
        saveCurrentListening()
        guard current != nil, !queue.isEmpty, order.indices.contains(position_) else {
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        let state = SavedState(queue: queue, order: order, index: position_, position: position,
                               shuffle: shuffle, repeatMode: repeatMode.rawValue, partyShuffle: playingPartyShuffle)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateFile, options: .atomic) }
    }

    func saveCurrentListening() {
        guard pendingID == nil, let current, !current.isMusic, position >= 0,
              position > 0 || current.resumePosition != nil else { return }
        library.saveListening(current.id, position: position)
    }

    func refreshImportedListening(for id: String) {
        guard current?.id == id, pendingID == nil else { return }
        loadCurrent(autoplay: isPlaying)
    }

    /// Puts the last session's song back, paused at the same spot (like iTunes did).
    func restoreState() {
        guard current == nil, let data = try? Data(contentsOf: stateFile),
              let s = try? JSONDecoder().decode(SavedState.self, from: data),
              s.order.indices.contains(s.index), s.queue.indices.contains(s.order[s.index]),
              library.track(s.queue[s.order[s.index]]) != nil else { return }
        queue = s.queue
        shuffle = s.shuffle
        repeatMode = RepeatMode(rawValue: s.repeatMode) ?? .off
        order = s.order.filter { s.queue.indices.contains($0) }
        position_ = order.firstIndex(of: s.order[s.index]) ?? 0
        playingPartyShuffle = s.partyShuffle
        let restoredTrack = library.track(s.queue[s.order[s.index]])
        let hasImportedPosition = restoredTrack?.isMusic == false &&
            (restoredTrack?.resumePosition != nil || restoredTrack?.finishedListening == true)
        loadCurrent(from: hasImportedPosition ? nil : s.position, autoplay: false)
        // loadCurrent only resets play counting when starting at 0; a resumed song counts on.
        countedCurrent = s.position > 0 && s.position >= min(duration * playThreshold, 240)
    }

    // MARK: Clock

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { PlayerEngine.shared.tick() }
        }
    }

    private func seconds(of d: Deck) -> Double? {
        guard d.file != nil, let rt = d.node.lastRenderTime, rt.isSampleTimeValid,
              let pt = d.node.playerTime(forNodeTime: rt) else { return nil }
        return Double(pt.sampleTime) / d.sampleRate
    }

    private func tick() {
        guard current != nil, isPlaying else { return }
        tickCount += 1

        // Has the next song begun?
        if armed, let s = seconds(of: decks[other]), s >= 0 {
            promote()
        }

        let d = decks[cur]
        guard let played = seconds(of: d), played >= 0 else { return }
        let t = Double(d.startFrame) / d.sampleRate + played

        // Crossfade: equal-power curves, driven by how far the new song has played.
        if let f = fadingOut {
            let p = min(1, max(0, played / max(f.length, 0.1)))
            d.node.volume = Float(sin(p * .pi / 2))
            decks[f.deck].node.volume = Float(cos(p * .pi / 2))
            if p >= 1 {
                halt(decks[f.deck])
                fadingOut = nil
            }
        }

        if !armed { armNext() }

        // Publish the position ~4 times a second (it drives a lot of UI).
        if tickCount % 8 == 0 || abs(t - position) > 1 {
            position = t
        }
        // Count only time actually played: small forward steps between ticks, not seek jumps.
        if let last = lastTickTime, t > last, t - last < 1 { listened += t - last }
        lastTickTime = t
        if !countedCurrent, duration > 0, listened >= min(duration * playThreshold, 240), let id = current?.id {
            countedCurrent = true
            failures = 0
            library.recordPlay(id)
            if let c = current { LastFM.shared.scrobble(c, at: startedAt) }
        }
        if tickCount % 30 == 0 { updateNowPlaying() }
        if tickCount % 900 == 0 { saveState() }
    }

    // MARK: Now Playing / media keys

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
    }

    func refreshDiscordPresence() {
        DiscordPresence.shared.update(track: current, playing: isPlaying && pendingID == nil, position: position, duration: duration)
    }

    private func updateNowPlaying() {
        refreshDiscordPresence()
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        center.playbackState = isPlaying ? .playing : .paused
    }
}
