import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.placeholderImage()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "MonoCl"
        statusItem = item
    }

    private static func placeholderImage() -> NSImage {
        let size = NSSize(width: 12, height: NSStatusBar.system.thickness)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let d: CGFloat = 8
            NSBezierPath(ovalIn: NSRect(
                x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d
            )).fill()
            return true
        }
    }
}
