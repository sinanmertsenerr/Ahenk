import CoreGraphics
import Foundation

/// The edge light shader's parameters for one strip and one frame.
///
/// Mirrors `EdgeLightUniforms` in EdgeLight.metal member for member
/// (432 bytes): Swift lays out stored properties in order with natural
/// alignment, as Metal does. The tests and the smoke check compare every
/// offset with the compiled shader's reflection, so a drift fails loudly.
public struct EdgeLightUniforms: Equatable, Sendable {
    // Geometry, in points (y up, origin at the screen's bottom-left corner).
    public var screenSize: SIMD2<Float> = .zero
    /// Bottom-left corner of the strip being drawn.
    public var stripOrigin: SIMD2<Float> = .zero
    public var stripSize: SIMD2<Float> = .zero
    /// Drawable pixels per point.
    public var pixelScale: Float = 1
    /// Light depth; alpha is exactly 0 from here inwards.
    public var band: Float = 0
    /// Corner radii in the shader's order: top-right, bottom-right,
    /// top-left, bottom-left.
    public var radii: SIMD4<Float> = .zero
    /// Notch: min x, width, height, corner radius (width 0: none).
    public var notch: SIMD4<Float> = .zero
    /// Perimeter coordinate radius, wrap length, corner arm, perimeter.
    public var perimeter: SIMD4<Float> = .zero

    // Look.
    public var thickness: Float = 10
    public var glow: Float = 0.6
    public var intensity: Float = 0.8
    /// Fade in/out (`0...1`).
    public var opacity: Float = 1
    /// ``LightMotion/drift``.
    public var time: Float = 0
    /// ``LightMotion/travel`` (`0..<1`).
    public var travel: Float = 0
    public var detail: Float = 1
    /// ``LightQuality/shaderValue``.
    public var quality: Float = 1
    public var style: Int32 = 0
    public var position: Int32 = 0
    /// 0: the colour slots, 1: rainbow.
    public var colorMode: Int32 = 0
    /// Different per screen, so particles do not repeat across displays.
    public var seed: Int32 = 0

    // Audio.
    public var energy: Float = 0
    public var beat: Float = 0
    public var onset: Float = 0
    public var beatPhase: Float = 0
    /// Sub-bass, bass, low-mid, mid.
    public var bands: SIMD4<Float> = .zero
    /// High band, swell, kick, tempo (bpm / 120, 0 while unknown).
    public var extra: SIMD4<Float> = .zero
    public var beatAges: SIMD4<Float> = SIMD4(repeating: LightMotion.noBeatAge)
    public var beatSeeds: SIMD4<Float> = .zero
    public var beatStrengths: SIMD4<Float> = .zero

    // Colours (`float4 colors[4]` in the shader).
    public var color0: SIMD4<Float> = .zero
    public var color1: SIMD4<Float> = .zero
    public var color2: SIMD4<Float> = .zero
    public var color3: SIMD4<Float> = .zero

    // Spectrum, 32 bands (`float4 spectrum[8]` in the shader).
    public var spectrum0: SIMD4<Float> = .zero
    public var spectrum1: SIMD4<Float> = .zero
    public var spectrum2: SIMD4<Float> = .zero
    public var spectrum3: SIMD4<Float> = .zero
    public var spectrum4: SIMD4<Float> = .zero
    public var spectrum5: SIMD4<Float> = .zero
    public var spectrum6: SIMD4<Float> = .zero
    public var spectrum7: SIMD4<Float> = .zero

    // Where the strip sits in the screen's atlas (``EdgeAtlas``).
    /// The slot's top-left corner in the target texture, in pixels.
    public var atlasOrigin: SIMD2<Float> = .zero
    /// 1 when the strip is stored turned a quarter.
    public var rotated: Int32 = 0
    public var reserved: Int32 = 0

    public init() {}

    public static let expectedSize = 432

    /// Byte offset of every member, by the shader's member names (arrays by
    /// their first element), for the layout check against the shader.
    public static let memberOffsets: [String: Int] = {
        var offsets: [String: Int] = [:]
        func record(_ name: String, _ path: PartialKeyPath<EdgeLightUniforms>) {
            offsets[name] = MemoryLayout<EdgeLightUniforms>.offset(of: path)
        }
        record("screenSize", \.screenSize)
        record("stripOrigin", \.stripOrigin)
        record("stripSize", \.stripSize)
        record("pixelScale", \.pixelScale)
        record("band", \.band)
        record("radii", \.radii)
        record("notch", \.notch)
        record("perimeter", \.perimeter)
        record("thickness", \.thickness)
        record("glow", \.glow)
        record("intensity", \.intensity)
        record("opacity", \.opacity)
        record("time", \.time)
        record("travel", \.travel)
        record("detail", \.detail)
        record("quality", \.quality)
        record("style", \.style)
        record("position", \.position)
        record("colorMode", \.colorMode)
        record("seed", \.seed)
        record("energy", \.energy)
        record("beat", \.beat)
        record("onset", \.onset)
        record("beatPhase", \.beatPhase)
        record("bands", \.bands)
        record("extra", \.extra)
        record("beatAges", \.beatAges)
        record("beatSeeds", \.beatSeeds)
        record("beatStrengths", \.beatStrengths)
        record("colors", \.color0)
        record("spectrum", \.spectrum0)
        record("atlasOrigin", \.atlasOrigin)
        record("rotated", \.rotated)
        record("reserved", \.reserved)
        return offsets
    }()
}

extension EdgeLightUniforms {
    /// The uniforms for one strip of one screen at one frame.
    ///
    /// - Parameters:
    ///   - metrics: the screen's outline and the light's depth.
    ///   - strip: the strip being drawn (points, y up).
    ///   - pixelScale: drawable pixels per point.
    ///   - look: style, line, halo, speed.
    ///   - colors: the four colour slots (``PaletteCrossfade/colors(at:)``).
    ///   - isRainbow: draw a hue wheel instead.
    ///   - motion: drift, travel, swell and the last beats.
    ///   - features: the audio features for this frame.
    ///   - time: the frame's time (``AudioClock`` seconds) for beat ages.
    ///   - opacity: the fade.
    ///   - quality: full or light.
    ///   - seed: per screen.
    ///   - slot: where the strip sits in the screen's atlas; `nil` when the
    ///     target holds just this strip, upright.
    public init(
        metrics: EdgeMetrics, strip: CGRect, pixelScale: Double, look: LightLook,
        colors: [SRGBColor], isRainbow: Bool, motion: LightMotion, features: AudioFeatures,
        time: Double, opacity: Double, quality: LightQuality, seed: Int32 = 0, slot: EdgeAtlasSlot? = nil
    ) {
        self.init()
        let shape = metrics.shape
        screenSize = SIMD2(Float(shape.width), Float(shape.height))
        stripOrigin = SIMD2(Float(strip.minX), Float(strip.minY))
        stripSize = SIMD2(Float(strip.width), Float(strip.height))
        self.pixelScale = Float(max(0.01, pixelScale))
        band = Float(metrics.band)
        let corners = shape.corners
        radii = SIMD4(Float(corners.topRight), Float(corners.bottomRight), Float(corners.topLeft), Float(corners.bottomLeft))
        if let notch = shape.notch {
            self.notch = SIMD4(Float(notch.minX), Float(notch.width), Float(notch.height), Float(notch.radius))
        }
        perimeter = SIMD4(Float(metrics.paramRadius), Float(metrics.wrap), Float(metrics.arm), Float(metrics.perimeter))

        thickness = Float(look.thickness)
        glow = Float(look.glow)
        intensity = Float(look.intensity)
        self.opacity = Float(min(1, max(0, opacity)))
        self.time = Float(motion.drift)
        travel = Float(motion.travel)
        detail = Float(look.detail)
        self.quality = quality.shaderValue
        style = look.style.shaderIndex
        position = look.position.shaderIndex
        colorMode = isRainbow ? 1 : 0
        self.seed = seed

        let audible = !features.isSilent
        energy = audible ? features.energy : 0
        beat = audible ? features.beat : 0
        onset = audible ? features.onset : 0
        beatPhase = audible ? features.beatPhase : 0
        let b = features.bands
        bands = audible ? SIMD4(b.subBass, b.bass, b.lowMid, b.mid) : .zero
        extra = SIMD4(audible ? b.high : 0, motion.swell, motion.kick, features.bpm > 0 ? features.bpm / 120 : 0)
        beatAges = motion.beatAges(at: time)
        beatSeeds = motion.beatSeeds
        beatStrengths = motion.beatStrengths

        let slots = LightColors.spread(colors)
        func vector(_ color: SRGBColor) -> SIMD4<Float> { SIMD4(Float(color.red), Float(color.green), Float(color.blue), 1) }
        color0 = vector(slots[0])
        color1 = vector(slots[1])
        color2 = vector(slots[2])
        color3 = vector(slots[3])

        let s = audible ? features.spectrum : .zero
        spectrum0 = SIMD4(s[0], s[1], s[2], s[3])
        spectrum1 = SIMD4(s[4], s[5], s[6], s[7])
        spectrum2 = SIMD4(s[8], s[9], s[10], s[11])
        spectrum3 = SIMD4(s[12], s[13], s[14], s[15])
        spectrum4 = SIMD4(s[16], s[17], s[18], s[19])
        spectrum5 = SIMD4(s[20], s[21], s[22], s[23])
        spectrum6 = SIMD4(s[24], s[25], s[26], s[27])
        spectrum7 = SIMD4(s[28], s[29], s[30], s[31])

        if let slot {
            atlasOrigin = SIMD2(Float(slot.pixels.minX), Float(slot.pixels.minY))
            rotated = slot.isRotated ? 1 : 0
        }
    }
}
