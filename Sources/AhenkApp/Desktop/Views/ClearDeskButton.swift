import SwiftUI

/// Clear Desk's own glyph, drawn in code: a crescent moon resting over a
/// short line, the desk. Outlined while the desk is as it was, filled while
/// it is cleared.
struct ClearDeskGlyph: View {
    var isOn: Bool

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let crescent = Self.crescent(side: side, origin: origin)
            let shading = GraphicsContext.Shading.foreground
            if isOn {
                context.fill(crescent, with: shading)
            } else {
                context.stroke(crescent, with: shading, style: StrokeStyle(lineWidth: max(1.2, side * 0.09), lineJoin: .round))
            }
            let desk = Path(roundedRect: CGRect(x: origin.x + side * 0.14, y: origin.y + side * 0.86, width: side * 0.72, height: max(1.2, side * 0.09)),
                            cornerRadius: side * 0.05)
            context.fill(desk, with: shading)
            if isOn {
                // A small spark beside the moon: the desk is clear.
                context.fill(Self.spark(center: CGPoint(x: origin.x + side * 0.8, y: origin.y + side * 0.2), radius: side * 0.13), with: shading)
            }
        }
        .accessibilityHidden(true)
    }

    /// A circle with a smaller one taken out of its upper right.
    static func crescent(side: CGFloat, origin: CGPoint) -> Path {
        let outer = Path(ellipseIn: CGRect(x: origin.x + side * 0.16, y: origin.y + side * 0.1, width: side * 0.62, height: side * 0.62))
        let inner = Path(ellipseIn: CGRect(x: origin.x + side * 0.36, y: origin.y + side * 0.0, width: side * 0.5, height: side * 0.5))
        return outer.subtracting(inner)
    }

    /// A four-pointed spark.
    static func spark(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let waist = radius * 0.28
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - waist, y: center.y - waist))
        path.closeSubpath()
        return path
    }
}

/// The round glass button beside the search field (and above the small
/// player) that clears the desk and brings it back.
struct ClearDeskButton: View {
    let isOn: Bool
    let tint: Color
    var accent: Color = .white
    let action: () -> Void

    var body: some View {
        let help = isOn ? "Bring the apps back".l10n : "Clear Desk".l10n
        Button(action: action) {
            ClearDeskGlyph(isOn: isOn)
                .frame(width: 15, height: 15)
                .foregroundStyle(isOn ? accent : .white.opacity(0.92))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .animation(.smooth(duration: 0.2), value: isOn)
        }
        .buttonStyle(PressableStyle(isOn: isOn, accent: accent))
        .help(help)
        .accessibilityLabel(help)
        .widgetGlass(Circle(), tint: tint)
    }
}
