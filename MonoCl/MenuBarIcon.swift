import AppKit
import Indicators

/// Draws the menu bar image from a specification.
///
/// The appearance is passed in rather than read from `NSApp`: the menu
/// bar's effective appearance differs from the application's, and using
/// the wrong one produces a glyph that is invisible against certain
/// wallpapers.  Callers pass `statusItem.button!.effectiveAppearance`.
@MainActor
enum MenuBarIcon {
    private static let inset: CGFloat = 2
    private static let glyphDiameter: CGFloat = 20
    private static let ringWidth: CGFloat = 3
    /// Centreline of the session ring, so its 3pt stroke lands inside
    /// the glyph box rather than straddling the edge of it.
    private static let ringRadius: CGFloat = glyphDiameter / 2 - ringWidth / 2
    private static let pieRadius: CGFloat = glyphDiameter / 2 - ringWidth - 1.5
    private static let platformGap: CGFloat = 6
    private static let platformRingRadius: CGFloat = 3
    private static let platformDiscRadius: CGFloat = 4

    static let width: CGFloat =
        inset + glyphDiameter + platformGap + platformDiscRadius + inset

    /// Where the breach slots are cut, as `NSBezierPath` measures
    /// angles.
    ///
    /// Inside the thresholds, not on them
    /// ---
    ///
    /// A slot at the 75% angle sits 3.6 degrees from the tip of a
    /// just-breached 76% gauge — about 0.53 pt of arc at the ring's
    /// 8.5 pt centreline radius, roughly one device pixel on a Retina
    /// display — so it reads as the arc ending rather than as a mark
    /// within it, and just-breached is exactly when the cue matters
    /// most.  Pulling the slots inward leaves drawn material on both
    /// sides of every cut.  They count severity; the arc length
    /// already reports the value.
    private static let markAngles: [CGFloat] = [angle(atPercent: 73), angle(atPercent: 88)]

    /// Clockwise from twelve o'clock, which is where every gauge starts.
    private static func angle(atPercent percent: CGFloat) -> CGFloat {
        90 - percent / 100 * 360
    }

    static func image(for spec: IconSpec, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: width, height: NSStatusBar.system.thickness)

        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let centre = NSPoint(x: inset + glyphDiameter / 2, y: rect.midY)
                draw(ring: spec.session, at: centre)
                draw(pie: spec.week, at: centre)
                draw(dot: spec.platform,
                     at: NSPoint(x: centre.x + glyphDiameter / 2 + platformGap, y: rect.midY))
            }
            return true
        }
        image.isTemplate = spec.isTemplate
        image.accessibilityDescription = accessibilityDescription(for: spec)
        return image
    }

    // MARK: - Parts

    private static func draw(ring gauge: GaugeSpec, at centre: NSPoint) {
        strokeArc(at: centre, radius: ringRadius, width: ringWidth,
                  sweep: 360, color: trackColor)
        if let fraction = gauge.fraction, fraction > 0 {
            strokeArc(at: centre, radius: ringRadius, width: ringWidth,
                      sweep: 360 * fraction, color: color(for: gauge.tint))
        }
        cut(gauge.breachMarks, at: centre,
            from: ringRadius - ringWidth / 2 - 0.5,
            to: ringRadius + ringWidth / 2 + 0.5)
    }

    private static func draw(pie gauge: GaugeSpec, at centre: NSPoint) {
        fillDisc(at: centre, radius: pieRadius, color: trackColor)
        if let fraction = gauge.fraction, fraction > 0 {
            fillWedge(at: centre, radius: pieRadius, sweep: 360 * fraction,
                      color: color(for: gauge.tint))
        }
        cut(gauge.breachMarks, at: centre, from: 0, to: pieRadius + 0.5)
    }

    private static func draw(dot: DotSpec, at centre: NSPoint) {
        switch dot.fill {
        case let .ring(faint):
            strokeCircle(at: centre, radius: platformRingRadius,
                         width: faint ? 1 : 1.5, color: color(for: dot.tint))
        case .filled:
            fillDisc(at: centre, radius: platformDiscRadius, color: color(for: dot.tint))
        }
        cut(dot.breachMarks, at: centre, from: 0, to: platformDiscRadius + 0.5)
    }

    /// Cuts radial slots through whatever has already been drawn.
    ///
    /// The slots are alpha rather than paint.  The menu bar's
    /// background is the user's wallpaper, so a gap painted in any
    /// colour would be a smear of the wrong one; and a template image
    /// takes its tint from the alpha channel, which is what the cut
    /// leaves behind.
    private static func cut(_ count: Int, at centre: NSPoint,
                            from innerRadius: CGFloat, to outerRadius: CGFloat) {
        guard count > 0, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        for degrees in markAngles.prefix(count) {
            let radians = degrees * .pi / 180
            let path = NSBezierPath()
            path.move(to: NSPoint(x: centre.x + cos(radians) * innerRadius,
                                  y: centre.y + sin(radians) * innerRadius))
            path.line(to: NSPoint(x: centre.x + cos(radians) * outerRadius,
                                  y: centre.y + sin(radians) * outerRadius))
            path.lineWidth = 1
            NSColor.black.setStroke()
            path.stroke()
        }
        context.restoreGraphicsState()
    }

    // MARK: - Primitives

    private static func strokeArc(at centre: NSPoint, radius: CGFloat, width: CGFloat,
                                  sweep: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .butt
        color.setStroke()
        path.stroke()
    }

    private static func strokeCircle(at centre: NSPoint, radius: CGFloat,
                                     width: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private static func fillDisc(at centre: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    private static func fillWedge(at centre: NSPoint, radius: CGFloat,
                                  sweep: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: centre)
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        path.close()
        color.setFill()
        path.fill()
    }

    private static var trackColor: NSColor { .labelColor.withAlphaComponent(0.18) }

    private static func color(for tint: DotSpec.Tint) -> NSColor {
        switch tint {
        case .monochrome: .labelColor
        case .dimmed: .labelColor.withAlphaComponent(0.35)
        case .amber: .systemOrange
        case .red: .systemRed
        }
    }

    // MARK: - Accessibility

    private static func accessibilityDescription(for spec: IconSpec) -> String {
        "Session \(describe(spec.session)), week \(describe(spec.week)), "
            + "platform \(name(for: spec.platform.tint))"
    }

    private static func describe(_ gauge: GaugeSpec) -> String {
        guard let fraction = gauge.fraction else { return name(for: gauge.tint) }
        return "\(Int((fraction * 100).rounded())) percent \(name(for: gauge.tint))"
    }

    private static func name(for tint: DotSpec.Tint) -> String {
        switch tint {
        case .monochrome: "normal"
        case .dimmed: "unknown"
        case .amber: "warning"
        case .red: "critical"
        }
    }
}
