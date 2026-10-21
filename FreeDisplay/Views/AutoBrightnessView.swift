import SwiftUI

/// "Auto Brightness" section — follows built-in screen brightness and adjusts external display brightness automatically.
struct AutoBrightnessView: View {
    @StateObject private var service = AutoBrightnessService.shared
    @State private var isHovered = false

    /// True only after the service has polled at least once and found no builtin display.
    private var builtinUnavailable: Bool {
        service.hasPolled && service.builtinBrightness <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main toggle
            HStack {
                MenuItemIcon(systemName: "sun.max.trianglebadge.exclamationmark", color: service.isEnabled ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Brightness")
                        .font(.body)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $service.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    // Only block *enabling* when there is no built-in display to follow.
                    // An already-enabled toggle must always stay clickable, otherwise the
                    // persisted setting can never be turned off again (e.g. on a Mac mini).
                    .disabled(builtinUnavailable && !service.isEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0))
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
    }

    private var statusText: String {
        if service.isEnabled {
            return builtinUnavailable
                ? "Enabled, but no built-in display detected (paused)"
                : "Syncing with built-in display brightness"
        } else if builtinUnavailable {
            return "No built-in display detected"
        } else {
            return "Match external displays to built-in display brightness"
        }
    }
}
