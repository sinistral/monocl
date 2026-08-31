import SwiftUI

@main
struct MonoClApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Text("Settings arrive in Task 13.")
                .padding()
                .frame(width: 320)
        }
    }
}
