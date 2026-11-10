import AhenkKit
import AppKit
import QuartzCore

/// Everything a style needs to draw: the text area's size, fonts and
/// colours, and the shared sprite cache.
struct LyricsRenderContext {
    /// The text area in points (layers use y up, origin bottom left).
    let size: CGSize
    /// Pixels per point of the screen it is drawn for.
    let scale: CGFloat
    /// Text centred in the column (no cover beside it), else leading.
    let centered: Bool
    /// Settings › Lyrics › Text size.
    let textScale: CGFloat
    /// The lines' colour: the cover's light colour, or white.
    let ink: SRGBColor
    /// Bright colours from the cover for glows, fills and accents.
    let accents: [SRGBColor]
    let sprites: LyricSpriteCache

    func accent(_ index: Int) -> SRGBColor {
        accents.isEmpty ? .white : accents[((index % accents.count) + accents.count) % accents.count]
    }
}

/// One moment of drawing: the lyric time, the audio and the clock.
struct LyricsFrame {
    /// The song's position plus the offsets (seconds).
    var time: TimeInterval
    /// `CACurrentMediaTime` of the frame (for flicker and hum).
    var hostTime: CFTimeInterval
    /// The audio features the styles use (see `AudioFeatures`).
    var beat: Double
    var beatPhase: Double
    var beatIndex: Int
    var energy: Double
    var onset: Double
    /// Seconds since the most recent beat (infinite before the first).
    var sinceBeat: Double
    var isPlaying: Bool

    init(time: TimeInterval, hostTime: CFTimeInterval, features: AudioFeatures, sinceBeat: Double, isPlaying: Bool) {
        self.time = time
        self.hostTime = hostTime
        beat = Double(features.beat)
        beatPhase = Double(features.beatPhase)
        beatIndex = features.beatIndex
        energy = Double(features.energy)
        onset = Double(features.onset)
        self.sinceBeat = sinceBeat
        self.isPlaying = isPlaying
    }
}

/// The layers of one lyric line: a container placed by the style and one
/// sprite layer per word or letter. Layers use y up; the layout is y down,
/// so `unitFrame` converts.
final class LyricLineVisual {
    let index: Int
    let layout: LyricLineLayout
    let container = CALayer()
    /// One per layout unit (nil sprites leave an empty layer).
    private(set) var units: [CALayer] = []
    private(set) var sprites: [LyricSprite?] = []
    /// Each unit layer's resting position (its centre, y up).
    private(set) var basePositions: [CGPoint] = []
    /// Style-specific layers (rows, copies, fills), keyed by the style.
    var extras: [String: [CALayer]] = [:]
    /// Last values set, to skip unchanged updates.
    var cache: [String: Double] = [:]
    /// Where each added layer rests and its size when it was added.
    private var resting: [ObjectIdentifier: (position: CGPoint, size: CGSize)] = [:]

    /// The resting position and size of a layer added by `addUnits`/`addRows`/`remember`.
    func rest(_ layer: CALayer) -> (position: CGPoint, size: CGSize) {
        resting[ObjectIdentifier(layer)] ?? (layer.position, layer.bounds.size)
    }

    /// Records `layer`'s current position and size as its resting place.
    func remember(_ layer: CALayer) {
        resting[ObjectIdentifier(layer)] = (layer.position, layer.bounds.size)
    }

    init(index: Int, layout: LyricLineLayout) {
        self.index = index
        self.layout = layout
        container.anchorPoint = .zero
        container.bounds = CGRect(origin: .zero, size: CGSize(width: max(1, layout.size.width), height: max(1, layout.size.height)))
        container.actions = LyricLayers.noActions
    }

    var height: CGFloat { layout.size.height }

    /// The frame of a sprite drawn for `rect` (a y-down box in the line),
    /// in the container's y-up coordinates.
    func spriteFrame(for rect: CGRect, sprite: LyricSprite) -> CGRect {
        CGRect(
            x: rect.minX - sprite.inset,
            y: layout.size.height - rect.maxY - sprite.inset,
            width: sprite.size.width,
            height: sprite.size.height
        )
    }

    /// Adds a layer per unit showing `sprite(unit)`.
    func addUnits(scale: CGFloat, sprite: (LyricLineLayout.Unit) -> LyricSprite?) {
        for unit in layout.units {
            let image = sprite(unit)
            let layer = LyricLayers.sprite(image, scale: scale)
            if let image { layer.frame = spriteFrame(for: unit.rect, sprite: image) }
            container.addSublayer(layer)
            units.append(layer)
            sprites.append(image)
            basePositions.append(layer.position)
            remember(layer)
        }
    }

    /// Adds one layer per row showing `sprite(row)` (row styles).
    @discardableResult
    func addRows(_ key: String, scale: CGFloat, below: Bool = false, sprite: (LyricLineLayout.Row) -> LyricSprite?) -> [CALayer] {
        var layers: [CALayer] = []
        for row in layout.rows {
            let image = sprite(row)
            let layer = LyricLayers.sprite(image, scale: scale)
            if let image { layer.frame = spriteFrame(for: row.rect, sprite: image) }
            if below {
                container.insertSublayer(layer, at: 0)
            } else {
                container.addSublayer(layer)
            }
            remember(layer)
            layers.append(layer)
        }
        extras[key] = layers
        return layers
    }

    /// Sets a value-tracked property only when it changed noticeably.
    func changed(_ key: String, _ value: Double, tolerance: Double = 0.002) -> Bool {
        if let old = cache[key], abs(old - value) < tolerance { return false }
        cache[key] = value
        return true
    }
}

enum LyricLayers {
    /// Layers move only when told to, without implicit animations.
    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull(), "contents": NSNull(),
        "contentsRect": NSNull(), "hidden": NSNull(), "frame": NSNull(), "anchorPoint": NSNull(), "strokeEnd": NSNull(),
        "path": NSNull(), "backgroundColor": NSNull(), "sublayers": NSNull(), "shadowOpacity": NSNull(),
    ]

    static func sprite(_ sprite: LyricSprite?, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.actions = noActions
        layer.contentsScale = scale
        layer.contents = sprite?.image
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        if let sprite { layer.bounds = CGRect(origin: .zero, size: sprite.size) }
        return layer
    }

    static func plain() -> CALayer {
        let layer = CALayer()
        layer.actions = noActions
        return layer
    }
}

/// The base of every style: keeps the visuals of the lines on screen
/// (made once per line, dropped when the line leaves), and offers the
/// slots lines glide between.
class LyricStyleRenderer {
    let style: LyricStyle
    let root = CALayer()
    private(set) var context: LyricsRenderContext?
    private(set) var timeline: LyricsTimeline?
    private var visuals: [Int: LyricLineVisual] = [:]
    private(set) var typesetter: LyricsTypesetter?

    init(style: LyricStyle) {
        self.style = style
        root.actions = LyricLayers.noActions
        root.anchorPoint = .zero
    }

    /// Units the style animates.
    var units: LyricsTypesetter.Units { .words }
    /// Most rows a line may take.
    var maxRows: Int { 3 }
    /// Letter spacing in points at text scale 1.
    var tracking: CGFloat { 0 }
    /// Row height as a multiple of the line height.
    var rowSpacing: CGFloat { 1.06 }
    /// Lines are wrapped to this share of the column width.
    var wrapShare: CGFloat { 1 }
    /// The style is laid out centred even beside the cover.
    var alwaysCentered: Bool { false }
    /// The style moves every frame even when no line glides (it then runs
    /// at the full frame rate).
    var animatesContinuously: Bool { false }
    /// Seconds a line takes to glide in, and how early it starts.
    var glide: TimeInterval { LyricsScene.glide }
    var lead: TimeInterval { LyricsScene.lead }

    var centered: Bool { alwaysCentered || (context?.centered ?? true) }

    func configure(_ context: LyricsRenderContext, timeline: LyricsTimeline?) {
        self.context = context
        self.timeline = timeline
        root.bounds = CGRect(origin: .zero, size: context.size)
        let font = LyricsFonts.font(for: style, scale: context.textScale)
        typesetter = LyricsTypesetter(font: font, tracking: tracking * context.textScale, rowSpacing: rowSpacing)
        clear()
        didConfigure()
    }

    /// After `configure`: build style-wide layers.
    func didConfigure() {}

    func clear() {
        visuals.values.forEach { $0.container.removeFromSuperlayer() }
        visuals = [:]
    }

    /// Draws one frame. Subclasses override.
    func render(_ scene: LyricsScene, frame: LyricsFrame) {}

    // MARK: Line visuals

    /// The visual of line `index`, made on first use.
    func visual(_ index: Int) -> LyricLineVisual? {
        if let visual = visuals[index] { return visual }
        guard let context, let timeline, let typesetter, timeline.lines.indices.contains(index) else { return nil }
        let width = context.size.width / wrapShare
        let layout = typesetter.layout(timeline.lines[index].text, width: width, maxRows: maxRows, units: units, centered: centered)
        let visual = LyricLineVisual(index: index, layout: layout)
        build(visual, context: context)
        root.addSublayer(visual.container)
        visuals[index] = visual
        return visual
    }

    /// Fills a new visual's layers. Subclasses override.
    func build(_ visual: LyricLineVisual, context: LyricsRenderContext) {}

    /// Drops every visual but those of `indices`.
    func keep(_ indices: Set<Int>) {
        for (index, visual) in visuals where !indices.contains(index) {
            visual.container.removeFromSuperlayer()
            visuals[index] = nil
        }
    }

    /// The lines a scene shows (current, leaving, waiting).
    func indices(of scene: LyricsScene, upcoming: Bool) -> Set<Int> {
        var indices: Set<Int> = []
        if let current = scene.current { indices.insert(current.index) }
        if let previous = scene.previous { indices.insert(previous.index) }
        if upcoming, let next = scene.upcoming { indices.insert(next) }
        return indices
    }

    // MARK: Helpers

    /// `text` drawn with `visual`'s font (a line that had to shrink to fit
    /// its rows has a smaller one), or the style's font.
    func sprite(_ text: String, ink: LyricInk, for visual: LyricLineVisual? = nil) -> LyricSprite? {
        guard let context, let typesetter else { return nil }
        let font = visual?.layout.font ?? typesetter.font
        let tracking = typesetter.tracking * (visual?.layout.fit ?? 1)
        return context.sprites.sprite(text, font: font, ink: ink, tracking: tracking, scale: context.scale)
    }

    /// The container of `visual` with its vertical centre at `centerY`
    /// (y up), scaled around its centre and faded.
    func place(_ visual: LyricLineVisual, centerY: CGFloat, dx: CGFloat = 0, scale: CGFloat = 1, opacity: CGFloat) {
        let container = visual.container
        let width = container.bounds.width
        let height = container.bounds.height
        if visual.changed("cy", Double(centerY), tolerance: 0.05) || visual.changed("dx", Double(dx), tolerance: 0.05)
            || visual.changed("cs", Double(scale), tolerance: 0.0005) {
            let size = context?.size ?? .zero
            let originX = centered ? (size.width - width) / 2 : 0
            // Centred lines scale around their middle, leading ones around
            // their left edge (so they stay aligned with the column).
            let pivot = centered ? width / 2 : 0
            var transform = CGAffineTransform(translationX: pivot, y: height / 2)
            transform = transform.scaledBy(x: scale, y: scale)
            transform = transform.translatedBy(x: -pivot, y: -height / 2)
            container.setAffineTransform(transform)
            container.position = CGPoint(x: originX + dx, y: centerY - height / 2)
        }
        // Lines fade out as they near the top or bottom of the area
        // instead of being cut off by the window's edge.
        let half = height * scale / 2
        let areaHeight = context?.size.height ?? height
        let over = max(centerY + half - (areaHeight + 10), (-10) - (centerY - half), 0)
        let edge = 1 - LyricsEasing.unit(Double(over / max(12, half * 0.9)))
        let shown = opacity * CGFloat(edge)
        if visual.changed("co", Double(shown), tolerance: 0.004) {
            container.opacity = Float(max(0, min(1, shown)))
        }
    }

    /// Where the current line's centre sits (a little above the middle).
    var currentCenter: CGFloat { (context?.size.height ?? 0) * 0.54 }

    /// Lines as a list that scrolls up one line at a time: the leaving line
    /// rides above the arriving one and the waiting one below it, so lines
    /// never overlap. Heights are the lines' heights at their scales.
    /// Returns the vertical centres (y up).
    func stack(
        current: CGFloat?, previous: CGFloat?, upcoming: CGFloat?, enter: Double, spacing: CGFloat,
        arrivingFrom arriving: CGFloat? = nil
    ) -> (current: CGFloat, previous: CGFloat, upcoming: CGFloat) {
        let center = currentCenter
        let e = CGFloat(LyricsEasing.outCubic(enter))
        guard let current else {
            // A line leaving into an instrumental part rises and fades.
            let height = previous ?? 0
            return (center, center + e * (height / 2 + 30), center)
        }
        let travel: CGFloat
        if let previous {
            travel = previous / 2 + spacing + (arriving ?? current) / 2
        } else {
            travel = 34
        }
        let currentY = center - (1 - e) * travel
        let previousY = currentY + current / 2 + spacing + (previous ?? 0) / 2
        let upcomingY = currentY - current / 2 - spacing - (upcoming ?? 0) / 2
        return (currentY, previousY, upcomingY)
    }
}

extension CALayer {
    /// Sets the opacity only if it changed (cheaper commits).
    func setOpacity(_ value: Double) {
        let clamped = Float(max(0, min(1, value)))
        if abs(opacity - clamped) > 0.003 { opacity = clamped }
    }

    func setPosition(_ point: CGPoint) {
        if abs(position.x - point.x) > 0.04 || abs(position.y - point.y) > 0.04 { position = point }
    }

    func setScale(_ scale: CGFloat) {
        let current = affineTransform()
        if abs(current.a - scale) > 0.0005 || abs(current.d - scale) > 0.0005 || current.b != 0 {
            setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }
}
