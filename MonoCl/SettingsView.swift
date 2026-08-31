import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let onChange: () -> Void

    var body: some View {
        Form {
            Section("Usage thresholds") {
                LabeledContent("Warning") {
                    Stepper(
                        value: $preferences.warningThreshold, in: 1...99, step: 1
                    ) {
                        Text("\(Int(preferences.warningThreshold))%")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Critical") {
                    Stepper(
                        value: $preferences.criticalThreshold, in: 1...150, step: 1
                    ) {
                        Text("\(Int(preferences.criticalThreshold))%")
                            .monospacedDigit()
                    }
                }
                Text("A light changes at or above its threshold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                LabeledContent("Interval") {
                    Stepper(
                        value: $preferences.refreshInterval, in: 15...600, step: 15
                    ) {
                        Text("\(Int(preferences.refreshInterval))s")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Treat as stale after") {
                    Stepper(
                        value: $preferences.staleAfter, in: 60...3600, step: 60
                    ) {
                        Text("\(Int(preferences.staleAfter / 60))m")
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onChange(of: preferences.warningThreshold) { _, _ in onChange() }
        .onChange(of: preferences.criticalThreshold) { _, _ in onChange() }
        .onChange(of: preferences.staleAfter) { _, _ in onChange() }
    }
}
