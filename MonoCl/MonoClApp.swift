import SwiftUI

@main
struct MonoClApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                preferences: appDelegate.preferences,
                onChange: { appDelegate.settingsChanged() }
            )
        }
    }
}
