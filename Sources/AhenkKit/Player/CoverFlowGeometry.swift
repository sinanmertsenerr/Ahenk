import Foundation

/// Where each album card of the cover flow sits for a continuous scroll
/// position: the card at the position faces the viewer at full size; the
/// others turn away around their vertical axis, shrink, darken and stack
/// up at the sides, nearer cards in front.
///
/// Positions are in cards (2.5 = halfway between the third and the fourth
/// album); a card's offset is its index minus the position.
public struct CoverFlowGeometry: Hashable, Sendable {
    /// Side of the centre card, in points.
    public var cardSide: Double
    /// From the centre card's centre to the first side card's centre.
    public var centerGap: Double
    /// Between two side cards further out.
    public var sideSpacing: Double
    /// The side cards' turn, in degrees.
    public var maxAngle: Double
    public var sideScale: Double
    /// Cards further than this from the position fade out.
    public var visibleRadius: Int

    public init(cardSide: Double = 150, centerGap: Double = 104, sideSpacing: Double = 46, maxAngle: Double = 50, sideScale: Double = 0.8, visibleRadius: Int = 3) {
        self.cardSide = cardSide
        self.centerGap = centerGap
        self.sideSpacing = sideSpacing
        self.maxAngle = maxAngle
        self.sideScale = sideScale
        self.visibleRadius = max(1, visibleRadius)
    }

    public struct Card: Hashable, Sendable {
        /// Horizontal offset of the card's centre from the carousel's centre.
        public var x: Double
        /// Turn around the vertical axis in degrees; cards on the right
        /// turn their faces to the left (negative), cards on the left to
        /// the right.
        public var angle: Double
        public var scale: Double
        /// Larger is in front.
        public var zIndex: Double
        public var opacity: Double
        /// 0 (none) to `maximumShade`: darkening of cards that turn away.
        public var shade: Double
    }

    public static let maximumShade = 0.62

    public func card(atOffset offset: Double) -> Card {
        guard offset.isFinite else { return Card(x: 0, angle: 0, scale: 1, zIndex: 0, opacity: 0, shade: 0) }
        let distance = abs(offset)
        let near = min(distance, 1)
        let sign: Double = offset < 0 ? -1 : 1
        let x = sign * (centerGap * near + sideSpacing * max(0, distance - 1))
        let opacity = distance <= Double(visibleRadius) ? 1 : max(0, 1 - (distance - Double(visibleRadius)))
        let shade = min(Self.maximumShade, 0.34 * near + 0.1 * max(0, distance - 1))
        return Card(
            x: x,
            angle: -sign * maxAngle * near,
            scale: 1 - (1 - sideScale) * near,
            zIndex: -distance,
            opacity: opacity,
            shade: shade
        )
    }

    /// Points of horizontal drag that move the carousel by one card.
    public var dragStep: Double { (centerGap + sideSpacing) / 2 }

    /// Total width the cards take at most (for the carousel's frame).
    public var width: Double {
        2 * (centerGap + sideSpacing * Double(visibleRadius - 1)) + cardSide * sideScale
    }

    /// The position while dragging by `translation` points from `start`;
    /// past the first and last card it moves at a third of the pace.
    public func position(dragging translation: Double, from start: Double, count: Int) -> Double {
        guard count > 0, translation.isFinite else { return 0 }
        let raw = start - translation / dragStep
        let last = Double(count - 1)
        if raw < 0 { return raw / 3 }
        if raw > last { return last + (raw - last) / 3 }
        return raw
    }

    /// Where a drag released at `position` with `velocity` (points per
    /// second, positive to the right) comes to rest: momentum carries it
    /// on by up to three cards.
    public func restingIndex(position: Double, velocity: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let fling = velocity.isFinite ? -velocity * 0.16 / dragStep : 0
        let projected = position + max(-3, min(3, fling))
        return Self.nearestIndex(to: projected, count: count)
    }

    public static func nearestIndex(to position: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard position.isFinite else { return 0 }
        return min(count - 1, max(0, Int(position.rounded())))
    }

    /// The cards worth drawing around `position`.
    public func visibleIndices(around position: Double, count: Int) -> ClosedRange<Int>? {
        guard count > 0, position.isFinite else { return nil }
        let reach = Double(visibleRadius) + 1
        let lower = max(0, Int((position - reach).rounded(.up)))
        let upper = min(count - 1, Int((position + reach).rounded(.down)))
        return lower <= upper ? lower...upper : nil
    }
}
