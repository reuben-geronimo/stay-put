import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("StayPut").font(.title2)

            Toggle("Enable cursor confinement", isOn: Binding(
                get: { appState.isEnabled },
                set: { appState.setEnabled($0) }
            ))

            Text("Mode: Menu Bar Guard (current screen).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = appState.statusMessage, !status.isEmpty {
                Text(status)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("If enabling fails, grant both Accessibility and Input Monitoring in System Settings → Privacy & Security, then try again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Open Input Monitoring Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 250)
    }
}
