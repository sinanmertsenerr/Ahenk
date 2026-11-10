import AhenkKit
import AppKit
import QuartzCore

// The two quiet lyric styles, built like the others (see LyricStyles.swift):
// a line's layers are made once, then only moved, scaled and faded.

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

private func readableInk(_ color: SRGBColor, shade: Double = 0.55, blur: Double = 8) -> LyricInk {
    LyricInk(color: color, shade: shade, shadeBlur: blur)
}

private extension LyricLineVisual {
    /// Where in the line (0…1 of its characters) each unit starts and ends.
    func span(_ unit: Int) -> (start: Double, end: Double) {
        let total = Double(max(1, layout.characterCount))
        let characters = layout.units[unit].characters
        return (Double(characters.lowerBound) / total, Double(characters.upperBound) / total)
    }

    /// How far a unit is into its own moment (0 before it is sung, 1 once
    /// `window` of the line has passed since it started).
    func reached(_ unit: Int, sung: Double, window: Double) -> Double {
        LyricsEasing.unit((sung - span(unit).start) / max(0.001, window) + (sung > 0 ? 0.0001 : 0))
    }

    /// The share of the line one word's moment takes.
    var wordWindow: Double { min(0.5, max(0.07, 1.1 / Double(max(1, layout.units.count)))) }
}

private extension LyricStyleRenderer {
    typealias Shown = (state: LyricsScene.LineState, visual: LyricLineVisual)

    /// The line being sung and the one leaving, with their layers.
    func shown(_ scene: LyricsScene) -> (current: Shown?, previous: Shown?) {
        keep(indices(of: scene, upcoming: false))
        let current = scene.current.flatMap { state in visual(state.index).map { (state, $0) } }
        let previous = scene.previous.flatMap { state in visual(state.index).map { (state, $0) } }
        return (current, previous)
    }
}

// MARK: - Plain

/// Nothing but the words: the line being sung in full, the next one
/// waiting smaller and dim below, the last one fading away above. Lines
/// move up one at a time; nothing reacts to the beat and nothing is drawn
/// between lines.
final class PlainStyle: LyricStyleRenderer {
    static let waiting: CGFloat = 0.86
    static let dim: CGFloat = 0.34

    override var maxRows: Int { 3 }
    override var rowSpacing: CGFloat { 1.04 }

    override func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {
        visual.addRows("main", scale: context.scale) { sprite($0.text, ink: readableInk(context.ink), for: visual) }
    }

    override func render(_ scene: LyricsScene, frame: LyricsFrame) {
        // The next line waits below, except in instrumental parts (the
        // countdown has the stage then).
        let waiting = scene.gap == nil
        keep(indices(of: scene, upcoming: waiting))
        let current = scene.current.flatMap { state in visual(state.index).map { (state, $0) } }
        let previous = scene.previous.flatMap { state in visual(state.index).map { (state, $0) } }
        let next = waiting ? scene.upcoming.flatMap { index in index == scene.current?.index ? nil : visual(index) } : nil
        let enter = current?.0.enter ?? 1
        let e = LyricsEasing.outCubic(enter)
        let currentScale = mix(Self.waiting, 1, e)
        let previousScale = current == nil ? 1 : mix(1, 0.9, e)
        let spots = stack(
            current: current.map { $0.1.height * currentScale }, previous: previous.map { $0.1.height * previousScale },
            upcoming: next.map { $0.height * Self.waiting }, enter: current == nil ? (scene.previous?.exit ?? 0) : enter, spacing: 14,
            arrivingFrom: current.map { $0.1.height * Self.waiting }
        )
        if let (_, visual) = current {
            place(visual, centerY: spots.current, scale: currentScale, opacity: mix(Self.dim, 1, e))
        }
        if let (state, visual) = previous {
            let fade = current == nil ? LyricsEasing.inOutCubic(state.exit) : e
            place(visual, centerY: spots.previous, scale: previousScale, opacity: CGFloat(1 - fade))
        }
        if let visual = next {
            place(visual, centerY: spots.upcoming, scale: Self.waiting, opacity: Self.dim * CGFloat(LyricsEasing.unit(enter * 1.5)))
        }
    }
}

// MARK: - Drift

/// Calm: words surface one after another and sway slowly, each at its own
/// pace; a leaving line comes apart and floats up like smoke.
final class DriftStyle: LyricStyleRenderer {
    override var maxRows: Int { 3 }
    override var rowSpacing: CGFloat { 1.1 }
    override var animatesContinuously: Bool { true }
    override var glide: TimeInterval { 0.8 }

    override func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {
        visual.addUnits(scale: context.scale) { sprite($0.text, ink: readableInk(context.ink, shade: 0.5, blur: 10), for: visual) }
    }

    override func render(_ scene: LyricsScene, frame: LyricsFrame) {
        let (current, previous) = shown(scene)
        let enter = current?.state.enter ?? (previous?.state.exit ?? 0)
        let spots = stack(current: current?.visual.height, previous: previous?.visual.height, upcoming: nil, enter: enter, spacing: 20)
        if let (state, visual) = current {
            drift(visual, enter: state.enter, sung: state.sung, exit: 0, frame: frame)
            place(visual, centerY: spots.current, opacity: 1)
        }
        if let (state, visual) = previous {
            drift(visual, enter: 1, sung: 1.5, exit: state.exit, frame: frame)
            place(visual, centerY: spots.previous, opacity: 1)
        }
    }

    private func drift(_ visual: LyricLineVisual, enter: Double, sung: Double, exit: Double, frame: LyricsFrame) {
        let size = Double(visual.layout.font.pointSize)
        let seed = UInt64(truncatingIfNeeded: visual.index)
        let count = Double(max(1, visual.units.count))
        for (index, layer) in visual.units.enumerated() {
            let base = visual.basePositions[index]
            let own = LyricsNoise.unit(seed, index)
            let side = LyricsNoise.signed(seed, index, 1)
            let surfaced = LyricsEasing.outCubic(LyricsEasing.unit(enter * 1.6 - Double(index) / count * 0.6))
            let gone = LyricsEasing.inOutCubic(exit)
            let sway = sin(frame.hostTime * (0.5 + 0.5 * own) + own * 6) * size * 0.035
            let x = Double(base.x) + side * size * 0.3 * (1 - surfaced) + sway + side * gone * size * 0.5
            let y = Double(base.y) - (1 - surfaced) * size * 0.25 + gone * size * (0.4 + 0.9 * own)
            layer.setPosition(CGPoint(x: x, y: y))
            // The word being sung is clear, the others a little softer.
            let near = 1 - LyricsEasing.unit(abs(sung - (visual.span(index).start + visual.span(index).end) / 2) * count * 0.55)
            layer.setOpacity((0.6 + 0.4 * max(near, sung >= 1 ? 1 : 0)) * surfaced * pow(1 - LyricsEasing.unit(exit * (0.9 + 0.5 * own)), 1.5))
        }
    }
}
