import SwiftUI
import Foundation

/// Lecture mode: keep playback alive with the physical monitor switched off.
/// It deliberately does not create a virtual display, because FairPlay/HDCP
/// protected course videos do not play on virtual displays.
struct LectureModeView: View {
    @ObservedObject private var sleep = SleepAssertionService.shared

    private var isOn: Binding<Bool> {
        Binding(
            get: { sleep.isHeld(by: .lecture) },
            set: { enabled in
                sleep.setHeld(
                    enabled,
                    by: .lecture,
                    reason: "FreeDisplay lecture playback",
                    preventDisplaySleep: false
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "play.rectangle.fill", color: .green)
                        .accessibilityHidden(true)
                    Text("Keep Playing (Prevent System Sleep)")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if sleep.isHeld(by: .lecture) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("System stays awake; displays can sleep normally")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button {
                    sleepDisplaysNow()
                } label: {
                    Label("Turn Off Display Now", systemImage: "display")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Put the display to sleep now while the Mac and playback keep running; press a key or move the mouse to wake it")
            }

            Text("No virtual display is created, so online classes and FairPlay/DRM video play normally. Once enabled, either wait for the display to sleep on its own or click the button above to turn it off now; the Mac stays awake and keeps playing.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func sleepDisplaysNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }
}
