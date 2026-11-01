//
//  WhiteNoise.swift
//  Wiser
//
//  Created by Marlin on 02/11/2026.
//

import AVFoundation
import SwiftUI

/// A soft, steady noise to focus to, made as it plays rather than from a recording, a little different in each ear:
/// brown noise, pink noise or rain. It plays on with the screen locked, alongside whatever else the phone is playing,
/// fades in and out rather than starting or stopping dead, and blends from one noise to another.
@Observable
final class WhiteNoise {
    static let shared = WhiteNoise()

    /// The noises there are.
    enum Sound: Int, CaseIterable, Identifiable {
        /// The deep, even rush of far-off water.
        case brown
        /// Softer at the top than white noise, fuller than brown: steady rain on a window.
        case pink
        /// Rain falling close by: a hush, and drops.
        case rain

        var id: Self { self }

        var name: LocalizedStringKey {
            switch self {
            case .brown: "Brown Noise"
            case .pink: "Pink Noise"
            case .rain: "Rain"
            }
        }
    }

    /// Which noise plays, kept for next time.
    var sound: Sound {
        didSet {
            UserDefaults.standard.set(sound.rawValue, forKey: Keys.sound)
            state.sound = sound.rawValue
        }
    }

    /// How loud it plays, from nothing to full, before the phone's own volume; kept for next time.
    var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Keys.volume)
            if isPlaying {
                state.target = level
            }
        }
    }

    /// Whether it's playing for a listen in Settings, session or not.
    private(set) var isListening = false

    /// Called when the noise stops by itself: headphones taken off, so it doesn't carry on out loud.
    @ObservationIgnored var onStopped: (() -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let state = NoiseState()
    @ObservationIgnored private var source: AVAudioSourceNode?
    /// Whether it plays for the session.
    @ObservationIgnored private var forSession = false
    @ObservationIgnored private var isPlaying = false
    /// The engine's wind-down once the noise has faded out, unless it's wanted again first.
    @ObservationIgnored private var windDown: Task<Void, Never>?

    private enum Keys {
        static let sound = "WhiteNoise.sound"
        static let volume = "WhiteNoise.volume"
    }

    private init() {
        let defaults = UserDefaults.standard
        sound = Sound(rawValue: defaults.integer(forKey: Keys.sound)) ?? .brown
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.78
        state.sound = sound.rawValue
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .ended
            MainActor.assumeIsolated {
                // A call or an alarm stops the engine; it picks up again after.
                if ended, let self, self.isPlaying {
                    try? self.engine.start()
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones out: stop, as music does, rather than go on out loud.
                if reason == .oldDeviceUnavailable, let self, self.isPlaying {
                    self.forSession = false
                    self.isListening = false
                    self.update()
                    self.onStopped?()
                }
            }
        }
    }

    /// Fades the noise in, or out, for the session.
    func play(_ playing: Bool) {
        forSession = playing
        update()
    }

    /// Fades the noise in, or out, to listen to in Settings, session or not.
    func listen(_ listening: Bool) {
        isListening = listening
        update()
    }

    private func update() {
        let playing = forSession || isListening
        guard playing != isPlaying else { return }
        isPlaying = playing
        windDown?.cancel()
        if playing {
            start()
            state.target = level
        } else {
            state.target = 0
            windDown = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.fadeSeconds * 3))
                guard let self, !Task.isCancelled, !self.isPlaying else { return }
                self.engine.stop()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// The level the noise plays at: the volume, squared, as the ear hears it, up to a little short of full.
    private var level: Float {
        Float(volume * volume) * 0.8
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: .mixWithOthers)
        try? session.setActive(true)
        if source == nil {
            let node = Self.source(of: state, sampleRate: engine.outputNode.inputFormat(forBus: 0).sampleRate)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            source = node
        }
        if !engine.isRunning {
            try? engine.start()
        }
    }

    /// The node the noise comes from, made away from the main actor: the audio thread calls into it.
    nonisolated private static func source(of state: NoiseState, sampleRate: Double) -> AVAudioSourceNode {
        let rate = Float(sampleRate)
        // How far the level moves toward where it's headed each sample, for a fade of about `fadeSeconds`, and
        // the noises toward the one chosen, over about a third of a second.
        let step = 1 - exp(-1 / (Float(fadeSeconds) * rate))
        let blend = 1 - exp(-1 / (0.3 * rate))
        let rain = Rain(rate: rate)
        return AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!) { _, _, frames, buffers in
            state.render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(buffers), step: step, blend: blend, rain: rain)
            return noErr
        }
    }

    nonisolated private static let fadeSeconds = 1.2
}

/// What the noise is made from, sample by sample, on the audio thread: each ear's noises, blended toward the one
/// chosen, and the level, easing toward where it's told to go.
nonisolated private final class NoiseState: @unchecked Sendable {
    /// Where the level is headed, and which noise: set from the main thread.
    var target: Float = 0
    var sound = 0
    private var level: Float = 0
    private var shares: (Float, Float, Float) = (0, 0, 0)
    private var ears = (Ear(), Ear())
    private var seed: UInt32 = 0x9E37_79B9

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer, step: Float, blend: Float, rain: Rain) {
        guard buffers.count == 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let target = self.target
        let sound = self.sound
        for i in 0..<frames {
            level += (target - level) * step
            shares.0 += ((sound == 0 ? 1 : 0) - shares.0) * blend
            shares.1 += ((sound == 1 ? 1 : 0) - shares.1) * blend
            shares.2 += ((sound == 2 ? 1 : 0) - shares.2) * blend
            left[i] = ears.0.next(shares, &seed, rain) * level
            right[i] = ears.1.next(shares, &seed, rain) * level
        }
    }
}

/// How the rain is made at a sample rate: a pink-noise hush with its rumble taken out, and drops, each a short burst of
/// noise, softened.
nonisolated private struct Rain {
    let highPass: Float
    let lowPass: Float
    let tickFade: Float
    let dropFade: Float
    let tickChance: Float
    let dropChance: Float

    init(rate: Float) {
        highPass = exp(-2 * .pi * 400 / rate)
        lowPass = exp(-2 * .pi * 7000 / rate)
        tickFade = exp(-1 / (0.0015 * rate))
        dropFade = exp(-1 / (0.010 * rate))
        tickChance = 150 / rate
        dropChance = 12 / rate
    }
}

/// One ear's noises, each as loud as the others.
nonisolated private struct Ear {
    private var walk: Float = 0
    private var pink: (Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0)
    private var hush: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var ticks: Float = 0
    private var drops: Float = 0
    private var patter: Float = 0

    mutating func next(_ shares: (Float, Float, Float), _ seed: inout UInt32, _ rain: Rain) -> Float {
        let white = Self.white(&seed)
        // Brown: a walk that drifts back toward the middle.
        walk = (walk + 0.02 * white) / 1.02
        // Pink: white noise through a bank of filters (Paul Kellet's).
        pink.0 = 0.99886 * pink.0 + white * 0.0555179
        pink.1 = 0.99332 * pink.1 + white * 0.0750759
        pink.2 = 0.96900 * pink.2 + white * 0.1538520
        pink.3 = 0.86650 * pink.3 + white * 0.3104856
        pink.4 = 0.55000 * pink.4 + white * 0.5329522
        pink.5 = -0.7616 * pink.5 - white * 0.0168980
        let pinkNoise = pink.0 + pink.1 + pink.2 + pink.3 + pink.4 + pink.5 + pink.6 + white * 0.5362
        pink.6 = white * 0.115926
        var out = shares.0 * walk * 3.52 + shares.1 * pinkNoise * 0.114
        if shares.2 > 0.0001 {
            // The hush: pink noise through two high-passes.
            let first = rain.highPass * (hush.0 + pinkNoise - hush.1)
            hush.1 = pinkNoise
            hush.0 = first
            let second = rain.highPass * (hush.2 + first - hush.3)
            hush.3 = first
            hush.2 = second
            // The drops: small ones often, bigger ones now and then, each a burst of noise dying away.
            ticks *= rain.tickFade
            drops *= rain.dropFade
            let size = Self.unit(&seed)
            if Self.unit(&seed) < rain.tickChance { ticks += 0.25 + 0.75 * size * size }
            if Self.unit(&seed) < rain.dropChance { drops += 0.4 + 0.6 * size }
            patter = rain.lowPass * patter + (1 - rain.lowPass) * Self.white(&seed) * (ticks + drops)
            out += shares.2 * (0.45 * second + 1.2 * patter) * 0.408
        }
        return out
    }

    /// Even noise between -1 and 1, from a xorshift: nothing that allocates or locks, on this thread.
    private static func white(_ seed: inout UInt32) -> Float {
        unit(&seed) * 2 - 1
    }

    /// Even noise between 0 and 1.
    private static func unit(_ seed: inout UInt32) -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed) / Float(UInt32.max)
    }
}
