import AVFoundation
import MediaToolbox
import Accelerate
import Combine
import os

/// Sits inside AVFoundation's audio path through an MTAudioProcessingTap on every player item:
/// applies the 10-band equalizer and keeps the latest samples for the spectrum display.
/// Everything here is touched from the real-time audio thread, so state is guarded by a lock
/// and nothing allocates on the hot path unless the EQ settings just changed.
final class AudioProcessor: @unchecked Sendable {
    static let shared = AudioProcessor()

    static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private var lock = os_unfair_lock()
    private var eqEnabled = false
    private var gains = [Float](repeating: 0, count: 10)
    private var preampDB: Float = 0
    private var version = 0
    /// ReplayGain: 0 off, 1 track, 2 album; plus a preamp in dB.
    private var rgMode = 0
    private var rgPreamp: Float = 0

    // Spectrum ring buffer (mono mix of channel 0), 2048 samples.
    private let ringSize = 2048
    private var ring = [Float](repeating: 0, count: 2048)
    private var ringPos = 0
    private var lastSampleRate: Double = 44100

    // MARK: Settings (any thread)

    func setEQ(enabled: Bool, gains: [Float], preamp: Float) {
        os_unfair_lock_lock(&lock)
        eqEnabled = enabled
        self.gains = Array((gains + [Float](repeating: 0, count: 10)).prefix(10))
        preampDB = preamp
        version += 1
        os_unfair_lock_unlock(&lock)
    }

    func setReplayGain(mode: Int, preamp: Float) {
        os_unfair_lock_lock(&lock)
        rgMode = mode
        rgPreamp = preamp
        os_unfair_lock_unlock(&lock)
    }

    fileprivate func replayGain() -> (Int, Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (rgMode, rgPreamp)
    }

    fileprivate func eqSnapshot() -> (enabled: Bool, gains: [Float], preamp: Float, version: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (eqEnabled, gains, preampDB, version)
    }

    fileprivate func currentVersion() -> (Int, Bool, Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (version, eqEnabled, preampDB)
    }

    func push(_ samples: UnsafePointer<Float>, count: Int, stride: Int, sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        lastSampleRate = sampleRate
        var p = ringPos
        for i in 0..<count {
            ring[p] = samples[i * stride]
            p += 1
            if p == ringSize { p = 0 }
        }
        ringPos = p
        os_unfair_lock_unlock(&lock)
    }

    /// The most recent `n` samples (n ≤ 2048), oldest first.
    func latestSamples(_ n: Int) -> (samples: [Float], sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var out = [Float](repeating: 0, count: n)
        var p = (ringPos - n + ringSize) % ringSize
        for i in 0..<n {
            out[i] = ring[p]
            p += 1
            if p == ringSize { p = 0 }
        }
        return (out, lastSampleRate)
    }

    func clearSamples() {
        os_unfair_lock_lock(&lock)
        for i in 0..<ringSize { ring[i] = 0 }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Attaching to player items

    /// Builds an audio mix that routes the track through the tap. Returns nil if the tap
    /// can't be created (playback then simply runs without EQ/spectrum).
    /// ReplayGain values for one song (dB gains, linear peaks; nil when unknown).
    struct Gains: Sendable {
        var track: Double?
        var album: Double?
        var trackPeak: Double?
        var albumPeak: Double?
    }

    func makeAudioMix(for track: AVAssetTrack, gains: Gains = Gains()) -> AVAudioMix? {
        let config = TapConfig(processor: self, gains: gains)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(config).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        withExtendedLifetime(config) {}
        guard status == noErr, let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: Filter design (RBJ cookbook peaking EQ)

    static func coefficients(gains: [Float], sampleRate: Double) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(bandFrequencies.count * 5)
        for (i, f0) in bandFrequencies.enumerated() {
            let g = Double(i < gains.count ? gains[i] : 0)
            if f0 >= sampleRate * 0.45 || abs(g) < 0.01 {
                out += [1, 0, 0, 0, 0]   // pass-through section
                continue
            }
            let a = pow(10, g / 40)
            let w0 = 2 * Double.pi * f0 / sampleRate
            let q = 1.41
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let a0 = 1 + alpha / a
            out += [(1 + alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha * a) / a0,
                    (-2 * cosw) / a0, (1 - alpha / a) / a0]
        }
        return out
    }
}

/// What a new tap needs: handed over once, while the tap is created.
private final class TapConfig {
    let processor: AudioProcessor
    let gains: AudioProcessor.Gains
    init(processor: AudioProcessor, gains: AudioProcessor.Gains) { self.processor = processor; self.gains = gains }
}

/// Per-tap state: each player item gets its own (the preloaded next song runs a second tap).
private final class TapContext {
    let processor: AudioProcessor
    let gains: AudioProcessor.Gains
    var sampleRate: Double = 44100
    var usable = false
    var interleaved = false
    var channels = 2
    var setup: vDSP_biquad_Setup?
    var delays: [UnsafeMutablePointer<Float>] = []
    var appliedVersion = -1
    let sections = AudioProcessor.bandFrequencies.count

    init(processor: AudioProcessor, gains: AudioProcessor.Gains) {
        self.processor = processor
        self.gains = gains
    }

    /// The ReplayGain factor for the current mode, limited so the song's peak can't clip.
    private func replayGainFactor() -> Float {
        let (mode, pre) = processor.replayGain()
        guard mode != 0 else { return 1 }
        let db: Double?
        let peak: Double?
        if mode == 2, let a = gains.album { db = a; peak = gains.albumPeak ?? gains.trackPeak }
        else { db = gains.track ?? gains.album; peak = gains.trackPeak ?? gains.albumPeak }
        guard let db else { return powf(10, pre / 20) }
        var factor = pow(10, (db + Double(pre)) / 20)
        if let peak, peak > 0 { factor = min(factor, 1 / peak) }
        return Float(factor)
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        channels = Int(max(1, format.mChannelsPerFrame))
        interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 && channels > 1
        usable = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        freeDelays()
        for _ in 0..<channels {
            let d = UnsafeMutablePointer<Float>.allocate(capacity: 2 * sections + 2)
            d.initialize(repeating: 0, count: 2 * sections + 2)
            delays.append(d)
        }
        appliedVersion = -1
    }

    func unprepare() {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        setup = nil
        freeDelays()
    }

    private func freeDelays() {
        for d in delays { d.deallocate() }
        delays.removeAll()
    }

    func process(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard usable, frames > 0 else { return }
        let (version, enabled, preamp) = processor.currentVersion()

        var rg = replayGainFactor()
        if rg != 1 {
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let total = frames * Int(max(1, buffer.mNumberChannels))
                vDSP_vsmul(ptr, 1, &rg, ptr, 1, vDSP_Length(total))
                if rg > 1 {
                    var lo: Float = -1, hi: Float = 1
                    vDSP_vclip(ptr, 1, &lo, &hi, ptr, 1, vDSP_Length(total))
                }
            }
        }

        if enabled {
            if version != appliedVersion {
                let snap = processor.eqSnapshot()
                let coeffs = AudioProcessor.coefficients(gains: snap.gains, sampleRate: sampleRate)
                if let old = setup { vDSP_biquad_DestroySetup(old) }
                setup = coeffs.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(sections)) }
                for d in delays { d.update(repeating: 0, count: 2 * sections + 2) }
                appliedVersion = version
            }
            var gain = powf(10, preamp / 20)
            var channelIndex = 0
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let perBuffer = Int(max(1, buffer.mNumberChannels))
                let total = frames * perBuffer
                if gain != 1 { vDSP_vsmul(ptr, 1, &gain, ptr, 1, vDSP_Length(total)) }
                if let setup {
                    for c in 0..<perBuffer where channelIndex + c < delays.count {
                        vDSP_biquad(setup, delays[channelIndex + c], ptr + c, vDSP_Stride(perBuffer),
                                    ptr + c, vDSP_Stride(perBuffer), vDSP_Length(frames))
                    }
                }
                // Keep the output from clipping hard when boosting.
                var lo: Float = -1, hi: Float = 1
                vDSP_vclip(ptr, 1, &lo, &hi, ptr, 1, vDSP_Length(total))
                channelIndex += perBuffer
            }
        }

        // Spectrum feed: first channel of the first buffer.
        if let first = abl.first, let data = first.mData {
            let ptr = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            processor.push(ptr, count: frames, stride: Int(max(1, first.mNumberChannels)), sampleRate: sampleRate)
        }
    }
}

// MARK: - C callbacks (no captures, so they convert to @convention(c))

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    guard let clientInfo else { return }
    let config = Unmanaged<TapConfig>.fromOpaque(clientInfo).takeUnretainedValue()
    let ctx = TapContext(processor: config.processor, gains: config.gains)
    tapStorageOut.pointee = Unmanaged.passRetained(ctx).toOpaque()
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.process(UnsafeMutableAudioBufferListPointer(bufferListInOut), frames: Int(numberFramesOut.pointee))
}

// MARK: - Equalizer settings (UI side)

struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Acoustic", gains: [4.5, 4.5, 3.5, 1, 1.5, 1.5, 3, 3.5, 3, 1.5]),
        EQPreset(name: "Bass Booster", gains: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Reducer", gains: [-5.5, -4.5, -3.5, -2.5, -1, 0, 0, 0, 0, 0]),
        EQPreset(name: "Classical", gains: [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]),
        EQPreset(name: "Dance", gains: [3.5, 6, 4.5, 0, 1.5, 3, 4.5, 4, 3, 0]),
        EQPreset(name: "Electronic", gains: [4, 3.5, 1, 0, -2, 2, 1, 1, 4, 4.5]),
        EQPreset(name: "Hip-Hop", gains: [4.5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        EQPreset(name: "Jazz", gains: [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]),
        EQPreset(name: "Late Night", gains: [4.5, 3, 2, -1, -2, -1, 1, 2.5, 3, 2.5]),
        EQPreset(name: "Loudness", gains: [5.5, 4, 0, 0, -2, 0, -1, -4.5, 4.5, 1]),
        EQPreset(name: "Pop", gains: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        EQPreset(name: "Rock", gains: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        EQPreset(name: "Small Speakers", gains: [5.5, 4, 3.5, 2.5, 1, 0, -1, -2, -3, -3.5]),
        EQPreset(name: "Spoken Word", gains: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 4.5, 4, 2.5, 0]),
        EQPreset(name: "Treble Booster", gains: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]),
        EQPreset(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2.5, -3.5, -4.5, -5.5]),
        EQPreset(name: "Vocal Booster", gains: [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5])
    ]
}

@MainActor
final class EqualizerModel: ObservableObject {
    static let shared = EqualizerModel()

    @Published var enabled: Bool { didSet { apply() } }
    @Published var gains: [Float] { didSet { apply() } }
    @Published var preamp: Float { didSet { apply() } }
    @Published var presetName: String

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "eq.enabled")
        gains = (d.array(forKey: "eq.gains") as? [Double])?.map { Float($0) } ?? [Float](repeating: 0, count: 10)
        preamp = Float(d.double(forKey: "eq.preamp"))
        presetName = d.string(forKey: "eq.preset") ?? "Flat"
        apply()
    }

    func choose(_ preset: EQPreset) {
        presetName = preset.name
        gains = preset.gains
    }

    /// Dragging a slider makes the setting "Manual", like iTunes.
    func setGain(_ value: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = value
        presetName = "Manual"
    }

    private func apply() {
        AudioProcessor.shared.setEQ(enabled: enabled, gains: gains, preamp: preamp)
        let d = UserDefaults.standard
        d.set(enabled, forKey: "eq.enabled")
        d.set(gains.map { Double($0) }, forKey: "eq.gains")
        d.set(Double(preamp), forKey: "eq.preamp")
        d.set(presetName, forKey: "eq.preset")
    }
}

// MARK: - Spectrum (UI side)

/// Turns the tap's recent samples into log-spaced bands, ~30 times a second, only while
/// something on screen is showing it.
@MainActor
final class SpectrumModel: ObservableObject {
    static let shared = SpectrumModel()

    @Published private(set) var levels = [Float](repeating: 0, count: 24)

    private var consumers = 0
    private var timer: Timer?
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let fftSetup: FFTSetup?
    private var window: [Float]

    private init() {
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
    }

    func attach() {
        consumers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in SpectrumModel.shared.tick() }
        }
    }

    func detach() {
        consumers = max(0, consumers - 1)
        if consumers == 0 {
            timer?.invalidate()
            timer = nil
            levels = [Float](repeating: 0, count: levels.count)
        }
    }

    private func tick() {
        guard let fftSetup else { return }
        let playing = PlayerEngine.shared.isPlaying
        let (raw, sampleRate) = AudioProcessor.shared.latestSamples(n)
        var samples = [Float](repeating: 0, count: n)
        vDSP_vmul(raw, 1, window, 1, &samples, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        // Log-spaced bands from 40 Hz to 16 kHz.
        let count = levels.count
        let binHz = sampleRate / Double(n)
        var next = levels
        for b in 0..<count {
            let f0 = 40 * pow(16000.0 / 40.0, Double(b) / Double(count))
            let f1 = 40 * pow(16000.0 / 40.0, Double(b + 1) / Double(count))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = min(n / 2 - 1, max(i0 + 1, Int(f1 / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            let avg = sum / Float(i1 - i0)
            let db = 10 * log10f(max(avg, 1e-12))
            let target = playing ? min(1, max(0, (db + 10) / 60)) : 0
            // Fast attack, slow fall, like a hardware meter.
            next[b] = target > next[b] ? target : max(0, next[b] - 0.04)
        }
        levels = next
    }
}
