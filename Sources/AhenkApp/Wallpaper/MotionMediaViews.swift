import AhenkKit
import AppKit
import CoreImage
import QuartzCore

/// Core Animation's pause and resume for a layer's own animations: a
/// paused layer costs nothing to draw.
@MainActor
enum LayerClock {
    static func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
    }

    static func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    static func rate(_ frameRate: Int) -> CAFrameRateRange {
        let preferred = Float(max(8, frameRate))
        return CAFrameRateRange(minimum: max(8, preferred / 2), maximum: preferred, preferred: preferred)
    }
}

// MARK: - The cover, blurred and slowly moving

/// The fallback wallpaper: the playing song's cover, blurred, a little more
/// saturated, filling the screen and drifting slowly (Core Animation in the
/// window server, at the power plan's frame rate). A new cover dissolves in.
@MainActor
final class CoverMotionView: WallpaperMediaView {
    private let drift = CALayer()
    private let picture = CALayer()
    private var frameRate: Int
    private var coverKey: String?
    private var isPlaying = false
    private var blurTask: Task<Void, Never>?

    /// Shared by every cover view; Core Image contexts are thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(candidate: WallpaperCandidate, plan: WallpaperPowerPlan, frame: NSRect) {
        frameRate = plan.animationFrameRate
        super.init(candidate: candidate, frame: frame)
        layer?.masksToBounds = true
        drift.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        picture.contentsGravity = .resizeAspectFill
        picture.actions = ["bounds": NSNull(), "position": NSNull()]
        drift.addSublayer(picture)
        layer?.addSublayer(drift)
        place()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// Larger than the view, so the drift never shows an edge. Done on
    /// every size change (a window that is never shown is never laid out).
    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = CGSize(width: bounds.width * 1.25, height: bounds.height * 1.25)
        drift.bounds = CGRect(origin: .zero, size: size)
        drift.position = CGPoint(x: bounds.midX, y: bounds.midY)
        picture.frame = drift.bounds
        CATransaction.commit()
        drift.removeAnimation(forKey: "drift")
        animate()
    }

    /// Shows `cover` (or the palette, while there is none). `key` names the
    /// cover; the same key changes nothing.
    func setCover(_ cover: CGImage?, palette: Palette, key: String) {
        guard key != coverKey else { return }
        coverKey = key
        blurTask?.cancel()
        let context = Self.context
        blurTask = Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                cover.flatMap { Self.blurred($0, context: context) } ?? Self.paletteImage(palette)
            }.value
            guard let self, !Task.isCancelled, self.coverKey == key else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = self.picture.contents == nil ? 0 : 1.2
            self.picture.add(fade, forKey: "cover")
            self.picture.contents = image
            self.markReady()
        }
    }

    override func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing { LayerClock.resume(drift) } else { LayerClock.pause(drift) }
    }

    override func apply(_ plan: WallpaperPowerPlan) {
        guard plan.animationFrameRate != frameRate else { return }
        frameRate = plan.animationFrameRate
        drift.removeAnimation(forKey: "drift")
        animate()
    }

    override func tearDown() {
        super.tearDown()
        blurTask?.cancel()
        drift.removeAllAnimations()
        picture.contents = nil
    }

    private func animate() {
        guard drift.animation(forKey: "drift") == nil, bounds.width > 0 else { return }
        let w = bounds.width * 0.04
        let h = bounds.height * 0.04
        let path = CAKeyframeAnimation(keyPath: "transform")
        path.values = [
            CATransform3DMakeScale(1.0, 1.0, 1),
            CATransform3DConcat(CATransform3DMakeScale(1.06, 1.06, 1), CATransform3DMakeTranslation(w, -h, 0)),
            CATransform3DConcat(CATransform3DMakeScale(1.12, 1.12, 1), CATransform3DMakeTranslation(-w * 0.6, h, 0)),
            CATransform3DConcat(CATransform3DMakeScale(1.04, 1.04, 1), CATransform3DMakeTranslation(-w, -h * 0.4, 0)),
        ].map { NSValue(caTransform3D: $0) }
        path.keyTimes = [0, 0.35, 0.7, 1]
        path.duration = 48
        path.autoreverses = true
        path.repeatCount = .infinity
        path.calculationMode = .cubic
        path.preferredFrameRateRange = LayerClock.rate(frameRate)
        drift.add(path, forKey: "drift")
        if !isPlaying { LayerClock.pause(drift) }
    }

    /// The cover at 480 px, blurred, a little more saturated and darker.
    nonisolated static func blurred(_ cover: CGImage, context: CIContext) -> CGImage? {
        let input = CIImage(cgImage: cover)
        let side = max(input.extent.width, input.extent.height)
        guard side > 0 else { return nil }
        let scale = min(1, 480 / side)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 16)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.18, kCIInputBrightnessKey: -0.05])
            .cropped(to: extent)
        return context.createCGImage(blurred, from: extent)
    }

    /// A soft diagonal blend of the palette, for a song without a cover yet.
    nonisolated static func paletteImage(_ palette: Palette) -> CGImage? {
        let colors = (palette.colors.isEmpty ? Palette.neutral.colors : palette.colors).map(\.cgColor)
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return context.makeImage()
    }
}

// MARK: - Generated motion (demo)

/// Ahenk's own motion for demo mode, in one of `WallpaperDemo.lookCount`
/// looks drawn from the song's palette: soft fields of colour moving in long
/// loops. The look standing in for the song's own video carries a band of
/// light that crosses the screen once per song, placed by the song's
/// position, so following the song (and seeking) can be seen.
@MainActor
final class GeneratedMotionView: WallpaperMediaView {
    private let look: Int
    private let colors: [SRGBColor]
    private let base = CAGradientLayer()
    private var fields: [CAGradientLayer] = []
    private let sweep = CAGradientLayer()
    /// The song's length when this look follows the song.
    private let songLength: TimeInterval?
    private var sweepStart: CFTimeInterval?
    private var frameRate: Int
    private var isPlaying = false
    private var pausedPosition: TimeInterval = 0

    init(candidate: WallpaperCandidate, look: Int, colors: [SRGBColor], plan: WallpaperPowerPlan, frame: NSRect) {
        self.look = look
        self.colors = colors.isEmpty ? Palette.neutral.colors : colors
        songLength = candidate.kind == .songVideo ? candidate.duration : nil
        frameRate = plan.animationFrameRate
        super.init(candidate: candidate, frame: frame)
        layer?.masksToBounds = true
        let quiet: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]
        base.actions = quiet
        layer?.addSublayer(base)
        for _ in 0..<Self.fieldCount(look) {
            let field = CAGradientLayer()
            field.actions = quiet
            layer?.addSublayer(field)
            fields.append(field)
        }
        sweep.actions = quiet
        sweep.isHidden = songLength == nil
        layer?.addSublayer(sweep)
        resize()
        DispatchQueue.main.async { [weak self] in self?.markReady() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
    }

    private static func fieldCount(_ look: Int) -> Int {
        switch look % 4 {
        case 0: 3
        case 1: 4
        case 2: 2
        default: 6
        }
    }

    private func color(_ index: Int, alpha: Double = 1) -> CGColor {
        colors[((index % colors.count) + colors.count) % colors.count].cgColor(alpha: alpha)
    }

    /// Places the layers for the view's size (a window that is never shown
    /// is never laid out) and starts their motion again.
    private func resize() {
        pausedPosition = currentPosition ?? pausedPosition
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrange()
        CATransaction.commit()
        restartAnimations()
    }

    /// The layers' resting places (also what an offscreen render shows).
    private func arrange() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        base.frame = bounds
        let style = look % 4
        let dark = color(colors.count - 1)
        switch style {
        case 0:
            base.colors = [color(0), color(1), dark]
            base.startPoint = CGPoint(x: 0.5, y: 1)
            base.endPoint = CGPoint(x: 0.5, y: 0)
        case 2:
            base.colors = [color(1), color(0), color(2)]
            base.startPoint = CGPoint(x: 0, y: 0)
            base.endPoint = CGPoint(x: 1, y: 1)
        default:
            base.colors = [dark, color(0), dark]
            base.locations = [0, 0.6, 1]
            base.startPoint = CGPoint(x: 0, y: 1)
            base.endPoint = CGPoint(x: 1, y: 0)
        }
        for (index, field) in fields.enumerated() {
            switch style {
            case 0:
                // Wide soft bands.
                field.type = .axial
                field.colors = [color(index + 1, alpha: 0), color(index + 1, alpha: 0.55), color(index + 1, alpha: 0)]
                field.startPoint = CGPoint(x: 0.5, y: 0)
                field.endPoint = CGPoint(x: 0.5, y: 1)
                field.frame = CGRect(x: -w * 0.1, y: h * (0.15 + 0.28 * Double(index)), width: w * 1.2, height: h * 0.45)
            case 3:
                // Thin falling streaks.
                field.type = .axial
                field.colors = [color(index, alpha: 0), color(index, alpha: 0.65), color(index, alpha: 0)]
                field.startPoint = CGPoint(x: 0.5, y: 1)
                field.endPoint = CGPoint(x: 0.5, y: 0)
                let x = w * (0.08 + 0.16 * Double(index))
                field.frame = CGRect(x: x, y: h * 0.2, width: max(3, w * 0.006), height: h * 0.5)
            default:
                // Glowing fields of colour.
                field.type = .radial
                field.colors = [color(index, alpha: 0.85), color(index, alpha: 0)]
                field.startPoint = CGPoint(x: 0.5, y: 0.5)
                field.endPoint = CGPoint(x: 1, y: 1)
                let side = max(w, h) * (0.55 + 0.1 * Double(index % 3))
                let spots = [(0.25, 0.65), (0.75, 0.35), (0.6, 0.8), (0.3, 0.25)]
                let spot = spots[index % spots.count]
                field.frame = CGRect(x: w * spot.0 - side / 2, y: h * spot.1 - side / 2, width: side, height: side)
            }
        }
        sweep.type = .axial
        sweep.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.frame = CGRect(x: -w * 0.12, y: 0, width: w * 0.12, height: h)
    }

    private func restartAnimations() {
        guard bounds.width > 0 else { return }
        let w = bounds.width, h = bounds.height
        let rate = LayerClock.rate(frameRate)
        for (index, field) in fields.enumerated() {
            field.removeAllAnimations()
            let period = 14 + Double(index) * 4.5
            switch look % 4 {
            case 0:
                let move = CABasicAnimation(keyPath: "position.y")
                move.byValue = h * (index.isMultiple(of: 2) ? 0.18 : -0.18)
                move.duration = period
                move.autoreverses = true
                move.repeatCount = .infinity
                move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                move.preferredFrameRateRange = rate
                field.add(move, forKey: "motion")
            case 3:
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = h * 1.3
                fall.toValue = -h * 0.3
                fall.duration = 3.5 + Double(index % 3) * 1.4
                fall.repeatCount = .infinity
                fall.timeOffset = Double(index) * 0.9
                fall.preferredFrameRateRange = rate
                field.add(fall, forKey: "motion")
            default:
                let wander = CAKeyframeAnimation(keyPath: "position")
                let center = field.position
                let reach = CGSize(width: w * 0.12, height: h * 0.12)
                wander.values = [
                    center, CGPoint(x: center.x + reach.width, y: center.y - reach.height * 0.5),
                    CGPoint(x: center.x - reach.width * 0.4, y: center.y + reach.height), center,
                ].map { NSValue(point: $0) }
                wander.duration = period * 1.6
                wander.repeatCount = .infinity
                wander.calculationMode = .cubic
                wander.preferredFrameRateRange = rate
                let breathe = CABasicAnimation(keyPath: "transform.scale")
                breathe.fromValue = 0.9
                breathe.toValue = 1.12
                breathe.duration = period * 0.7
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.preferredFrameRateRange = rate
                let group = CAAnimationGroup()
                group.animations = [wander, breathe]
                group.duration = .infinity
                group.preferredFrameRateRange = rate
                field.add(group, forKey: "motion")
            }
        }
        if look % 4 == 2 {
            let turn = CABasicAnimation(keyPath: "endPoint")
            turn.fromValue = NSValue(point: CGPoint(x: 1, y: 1))
            turn.toValue = NSValue(point: CGPoint(x: 0, y: 1))
            turn.duration = 26
            turn.autoreverses = true
            turn.repeatCount = .infinity
            turn.preferredFrameRateRange = rate
            base.add(turn, forKey: "motion")
        }
        placeSweep(at: pausedPosition)
        if !isPlaying { LayerClock.pause(layer!) }
    }

    /// The band of light at `position` seconds into the song.
    private func placeSweep(at position: TimeInterval) {
        guard let length = songLength, length > 0, bounds.width > 0, let root = layer else { return }
        sweep.removeAnimation(forKey: "song")
        let cross = CABasicAnimation(keyPath: "position.x")
        cross.fromValue = -bounds.width * 0.06
        cross.toValue = bounds.width * 1.06
        cross.duration = length
        cross.repeatCount = .infinity
        cross.preferredFrameRateRange = LayerClock.rate(frameRate)
        let now = root.convertTime(CACurrentMediaTime(), from: nil)
        let start = now - max(0, min(length, position))
        cross.beginTime = sweep.convertTime(start, from: root)
        sweep.add(cross, forKey: "song")
        sweepStart = start
    }

    override func setPlaying(_ playing: Bool) {
        guard let root = layer, playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            LayerClock.resume(root)
        } else {
            pausedPosition = currentPosition ?? pausedPosition
            LayerClock.pause(root)
        }
    }

    override func seek(to seconds: TimeInterval) {
        guard songLength != nil else { return }
        pausedPosition = max(0, seconds)
        placeSweep(at: pausedPosition)
    }

    private var currentPosition: TimeInterval? {
        guard let length = songLength, let start = sweepStart, let root = layer else { return nil }
        let elapsed = root.convertTime(CACurrentMediaTime(), from: nil) - start
        return length > 0 ? elapsed.truncatingRemainder(dividingBy: length) : nil
    }

    override func position(_ answer: @escaping @MainActor (TimeInterval?, TimeInterval?) -> Void) {
        answer(currentPosition, songLength)
    }

    override func apply(_ plan: WallpaperPowerPlan) {
        guard plan.animationFrameRate != frameRate else { return }
        pausedPosition = currentPosition ?? pausedPosition
        frameRate = plan.animationFrameRate
        restartAnimations()
    }

    override func tearDown() {
        super.tearDown()
        layer?.sublayers?.forEach { $0.removeAllAnimations() }
    }
}
