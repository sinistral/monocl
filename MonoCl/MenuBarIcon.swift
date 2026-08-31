import AppKit
import Indicators

/// Draws the three-dot menu bar image from a specification.
///
/// The appearance is passed in rather than read from `NSApp`: the menu
/// bar's effective appearance differs from the application's, and using
/// the wrong one produces dots that are invisible against certain
/// wallpapers.  Callers pass `statusItem.button!.effectiveAppearance`.
@MainActor
enum MenuBarIcon {
    static let dotDiameter: CGFloat = 8
    static let dotGap: CGFloat = 4
    static let horizontalInset: CGFloat = 2

    static func image(for spec: IconSpec, appearance: NSAppearance) -> NSImage {
        let count = CGFloat(spec.dots.count)
        let width = count * dotDiameter + max(0, count - 1) * dotGap + horizontalInset * 2
        let size = NSSize(width: width, height: NSStatusBar.system.thickness)

        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                for (index, dot) in spec.dots.enumerated() {
                    let x = horizontalInset + CGFloat(index) * (dotDiameter + dotGap)
                    let frame = NSRect(
                        x: x,
                        y: rect.midY - dotDiameter / 2,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    draw(dot, in: frame)
                }
            }
            return true
        }
        image.isTemplate = spec.isTemplate
        image.accessibilityDescription = accessibilityDescription(for: spec)
        return image
    }

    private static func draw(_ dot: DotSpec, in frame: NSRect) {
        color(for: dot.tint).setStroke()
        color(for: dot.tint).setFill()

        switch dot.fill {
        case .ring:
            let path = NSBezierPath(ovalIn: frame.insetBy(dx: 0.75, dy: 0.75))
            path.lineWidth = 1.5
            path.stroke()

        case .filled:
            NSBezierPath(ovalIn: frame).fill()

        case .notched:
            // A gap at the top makes critical distinguishable from
            // warning by shape alone, for the differentiate-without-color
            // accessibility setting.
            let path = NSBezierPath()
            path.appendArc(
                withCenter: NSPoint(x: frame.midX, y: frame.midY),
                radius: frame.width / 2,
                startAngle: 115,
                endAngle: 65,
                clockwise: false
            )
            path.line(to: NSPoint(x: frame.midX, y: frame.midY))
            path.close()
            path.fill()
        }
    }

    private static func color(for tint: DotSpec.Tint) -> NSColor {
        switch tint {
        case .monochrome: .labelColor
        case .dimmed: .labelColor.withAlphaComponent(0.35)
        case .amber: .systemOrange
        case .red: .systemRed
        }
    }

    /// The three-dot guarantee is enforced elsewhere (`IndicatorStore.states`),
    /// not here, so this zips rather than indexes: a mismatched dot count
    /// yields a shorter description instead of a crash.
    private static func accessibilityDescription(for spec: IconSpec) -> String {
        let labels = ["Session", "week", "platform"]
        return zip(labels, spec.dots)
            .map { label, dot in "\(label) \(tintName(dot.tint))" }
            .joined(separator: ", ")
    }

    private static func tintName(_ tint: DotSpec.Tint) -> String {
        switch tint {
        case .monochrome: "normal"
        case .dimmed: "unknown"
        case .amber: "warning"
        case .red: "critical"
        }
    }
}
