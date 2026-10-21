import SwiftUI

/// "Auto Brightness" section — follows built-in screen brightness and adjusts external display brightness automatically.
///
/// The built-in panel's brightness already includes macOS's ambient-light auto brightness, so
/// mirroring the *value* is what ties this feature to the system setting; reading the setting
/// itself is not needed (and has no reliable API).
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
                        .fixedSize(horizontal: false, vertical: true)
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

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 2)

            detailRow("Built-in brightness", builtinBrightnessText)
            detailRow("External displays", syncTargetText, valueColor: syncTargetColor)
                .help("Virtual displays are never synced — they have no backlight.")
        }
        .task {
            // One-shot: with polling on, the 2 s loop already keeps this current. With
            // polling off, this is what gives the panel a value to display.
            if !service.isEnabled {
                service.refreshBuiltinBrightnessOnce()
            }
        }
    }

    // MARK: - Status

    private var statusText: String {
        if service.isEnabled {
            return builtinUnavailable
                ? "Enabled, but no built-in display detected (paused)"
                : "Syncing external displays with the built-in brightness"
        }
        if builtinUnavailable {
            return "No built-in display detected"
        }
        return "Match external displays to built-in display brightness"
    }

    private var builtinBrightnessText: String {
        service.builtinBrightness > 0
            ? "\(Int((service.builtinBrightness * 100).rounded()))%"
            : "—"
    }

    private var syncTargetText: String {
        switch service.syncTargetCount {
        case 0: return "None connected"
        case 1: return "1 display"
        default: return "\(service.syncTargetCount) displays"
        }
    }

    private var syncTargetColor: Color {
        service.syncTargetCount == 0 ? .secondary : .primary
    }

    // MARK: - Detail row

    private func detailRow(_ label: String, _ value: String, valueColor: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2)
                .foregroundColor(valueColor)
                .monospacedDigit()
        }
        // Align under the header's text column (12 padding + 18 icon + 8 spacing).
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
    }
}
