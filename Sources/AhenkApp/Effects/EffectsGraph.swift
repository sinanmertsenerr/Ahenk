import AhenkKit
import AVFoundation

/// The stages of the sound effects as audio engine nodes, in the order of
/// `SoundEffectChain`: pitch → equalizer → echo → reverb. (The orbit works
/// on the samples before they enter the engine, see `SoundOrbiter`; speed
/// belongs to the player.)
///
/// The same graph serves both players: an engine in manual rendering mode
/// inside Ahenk's own player (`LocalEffectsProcessor`), and an engine that
/// plays to the output device for other apps (`EffectsOutput`). A stage
/// that has nothing to do is bypassed, so it costs nothing.
///
/// The pitch stage is different: the engine's time-pitch node holds the
/// sound back by ``pitchDelayFrames`` even while bypassed, so it is only
/// wired in while the pitch is shifted (``setPitchWired(_:)``), and the
/// light waits that long for the sound (`AudioTapEngine.setEffectsDelay`).
final class EffectsGraph {
    let pitch = AVAudioUnitTimePitch()
    let equalizer = AVAudioUnitEQ(numberOfBands: SoundEffectSettings.equalizerFrequencies.count)
    let echo = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    private(set) var chain = SoundEffectChain.neutral
    /// The pitch stage sits between the source and the equalizer.
    private(set) var isPitchWired = false
    private var loadedSpace: ReverbSpace?
    private weak var engine: AVAudioEngine?
    private weak var source: AVAudioNode?
    private var format: AVAudioFormat?

    /// Frames the time-pitch node holds the sound back by, whatever the
    /// size of the render calls (measured; the smoke check measures it again).
    static let pitchDelayFrames = 4096

    /// Share of the reverb in what is heard with the slider all the way up
    /// (some of the dry sound always stays).
    static let fullReverb: Float = 80

    init() {
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Float(SoundEffectSettings.equalizerFrequencies[index])
            // One octave wide: neighbouring bands meet halfway.
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        pitch.rate = 1
        echo.lowPassCutoff = 12_000
        apply(.neutral)
    }

    /// Puts the stages between `source` and the engine's main mixer, with
    /// or without the pitch stage.
    func install(in engine: AVAudioEngine, from source: AVAudioNode, format: AVAudioFormat, pitchWired: Bool) {
        self.engine = engine
        self.source = source
        self.format = format
        isPitchWired = pitchWired
        for node in [pitch, equalizer, echo, reverb] as [AVAudioNode] { engine.attach(node) }
        if pitchWired {
            engine.connect(source, to: pitch, format: format)
            engine.connect(pitch, to: equalizer, format: format)
        } else {
            engine.connect(source, to: equalizer, format: format)
        }
        engine.connect(equalizer, to: echo, format: format)
        engine.connect(echo, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
    }

    /// Wires the pitch stage in or out of an engine that plays to a device
    /// (the engine takes new connections while it runs). Not for an engine
    /// that another thread renders by hand.
    func setPitchWired(_ wired: Bool) {
        guard wired != isPitchWired, let engine, let source, let format else { return }
        isPitchWired = wired
        engine.disconnectNodeOutput(source)
        if wired {
            engine.connect(source, to: pitch, format: format)
            engine.connect(pitch, to: equalizer, format: format)
        } else {
            engine.disconnectNodeOutput(pitch)
            engine.connect(source, to: equalizer, format: format)
        }
    }

    /// Sets every stage from `chain`; safe while audio flows.
    func apply(_ chain: SoundEffectChain) {
        self.chain = chain
        pitch.pitch = Float(chain.pitchCents)
        pitch.bypass = !chain.shiftsPitch

        for (index, band) in equalizer.bands.enumerated() where index < chain.equalizerGains.count {
            band.gain = Float(chain.equalizerGains[index])
        }
        equalizer.globalGain = Float(chain.headroom)
        equalizer.bypass = !chain.equalizes

        if let echo = chain.echo, chain.echoes {
            self.echo.delayTime = echo.delay
            self.echo.feedback = Float(echo.feedback * 100)
            self.echo.wetDryMix = Float(echo.mix * 100)
            self.echo.bypass = false
        } else {
            echo.wetDryMix = 0
            echo.bypass = true
        }

        if chain.reverberates {
            if loadedSpace != chain.space {
                reverb.loadFactoryPreset(Self.preset(for: chain.space))
                loadedSpace = chain.space
            }
            reverb.wetDryMix = Float(chain.reverbMix) * Self.fullReverb
            reverb.bypass = false
        } else {
            reverb.wetDryMix = 0
            reverb.bypass = true
        }
    }

    static func preset(for space: ReverbSpace) -> AVAudioUnitReverbPreset {
        switch space {
        case .room: .mediumRoom
        case .chamber: .mediumChamber
        case .hall: .mediumHall
        case .largeHall: .largeHall2
        case .plate: .plate
        case .cathedral: .cathedral
        }
    }
}
