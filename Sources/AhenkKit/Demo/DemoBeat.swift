import Foundation

/// Synthetic audio features for the demo: a four-on-the-floor kick at
/// 120 BPM, off-beat hi-hats, a slow chord swell and a 32-second dynamic arc.
/// A pure function of the song position, so it is exactly reproducible.
public enum DemoBeat {
    public static let bpm: Double = 120

    public static func features(at position: TimeInterval, bpm: Double = bpm) -> AudioFeatures {
        let beatLength = 60 / bpm
        let beats = max(0, position) / beatLength
        let beatIndex = Int(beats.rounded(.down))
        let phase = beats - Double(beatIndex)

        // Kick on every beat, accented on the first beat of each bar.
        let accent = beatIndex.isMultiple(of: 4) ? 1.0 : 0.82
        let kick = exp(-phase * 6) * accent
        // Hi-hat on the off-beat (half-way through each beat).
        let hatPhase = (phase + 0.5).truncatingRemainder(dividingBy: 1)
        let hat = exp(-hatPhase * 14)
        // Chords move every bar; the whole song breathes over 32 seconds.
        let swell = 0.75 + 0.25 * sin(2 * .pi * position / 32)
        let chords = 0.45 + 0.25 * sin(2 * .pi * position / (beatLength * 4))

        let bass = kick * swell
        let mid = chords * swell
        let treble = hat * 0.7 * swell

        var bands = SIMD16<Float>()
        for band in 0..<AudioFeatures.bandCount {
            let x = Double(band) / Double(AudioFeatures.bandCount - 1)
            // Low bands follow the kick, middle ones the chords, top ones the hats.
            let low = max(0, 1 - x * 3) * bass
            let middle = max(0, 1 - abs(x - 0.45) * 3) * mid * (0.85 + 0.15 * sin(position * 3 + Double(band)))
            let high = max(0, (x - 0.55) * 2.2) * treble
            bands[band] = Float(min(1, low + middle + high))
        }

        // Onsets: sharp at the kick, softer at the hat.
        let kickOnset = phase < 0.08 ? 1 - phase / 0.08 : 0
        let hatOnset = hatPhase < 0.06 ? (1 - hatPhase / 0.06) * 0.5 : 0
        let level = min(1, 0.5 * bass + 0.3 * mid + 0.2 * treble)

        return AudioFeatures(
            level: Float(level),
            bass: Float(min(1, bass)),
            mid: Float(min(1, mid)),
            treble: Float(min(1, treble)),
            bands: bands,
            onset: Float(max(kickOnset * accent, hatOnset)),
            beat: Float(min(1, kick)),
            beatPhase: Float(phase),
            beatIndex: beatIndex,
            bpm: Float(bpm),
            isSilent: false
        )
    }
}
