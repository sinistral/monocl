import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let onChange: () -> Void

    private var staleAfterFloor: TimeInterval { preferences.refreshInterval * 2 }

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
                        value: $preferences.refreshInterval, in: 60...900, step: 60
                    ) {
                        Text("\(Int(preferences.refreshInterval))s")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Treat as stale after") {
                    // The lower bound tracks the read clamp on
                    // `staleAfter`.  A fixed one would let the stepper
                    // write below the clamp, where the control looks
                    // frozen while the stored value drifts away from
                    // the figure on screen.  The upper bound yields to
                    // it rather than the other way round: a stored
                    // interval above 1800 s is reachable by editing
                    // defaults directly, and an inverted range traps.
                    Stepper(
                        value: $preferences.staleAfter,
                        in: staleAfterFloor...max(3600, staleAfterFloor),
                        step: 60
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
        // The interval is not merely a cadence: `staleAfter` is derived
        // from it, so changing it changes what counts as stale.
        .onChange(of: preferences.refreshInterval) { _, _ in onChange() }
        .onChange(of: preferences.staleAfter) { _, _ in onChange() }
    }
}
