import AppKit

// MonoCl is an AppKit app that renders one SwiftUI view.  It was a
// SwiftUI `App` with a `Settings` scene, but on macOS 26 the only way
// to open that scene from AppKit -- sending `showSettingsWindow:` --
// returns `true` without opening anything, and the documented
// replacement (`@Environment(\.openSettings)`) is reachable only from
// inside a SwiftUI view, which a menu bar app built on NSStatusItem
// never has on screen.  The window is AppKit's, so AppDelegate owns it.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
