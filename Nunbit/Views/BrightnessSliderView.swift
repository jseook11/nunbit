import SwiftUI
import Combine

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var valueHighlighted: Bool = false
    @State private var highlightTask: Task<Void, Never>?
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software
    /// Throttle DDC writes during drag to ~100ms intervals.
    @State private var lastDDCWrite: Date = .distantPast

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row
            HStack(spacing: 4) {
                Spacer()
                if display.isBuiltin {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("System")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if let status = ddcStatus {
                    Circle()
                        .fill(status ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(status ? "DDC" : "Software")
                        .font(.caption2)
                        .foregroundColor(status ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(display.isBuiltin ? "Brightness control mode: System" : "Brightness control mode: \(ddcStatus == true ? "DDC hardware" : "Software emulation")")
            .help(display.isBuiltin ? "System brightness: controls built-in display brightness through the system API" : "DDC: hardware brightness control\nSoftware: brightness adjusted in software")

            HStack(spacing: 6) {
                let sunIcon: String = {
                    if localBrightness < 30 { return "sun.min" }
                    else if localBrightness < 70 { return "sun.min.fill" }
                    else { return "sun.max.fill" }
                }()
                Image(systemName: sunIcon)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(width: 14)
                    .animation(.easeInOut(duration: 0.2), value: sunIcon)
                    .accessibilityHidden(true)

                Slider(value: $localBrightness, in: 5...100, step: 1) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag ended — apply final value with smooth transition and show highlight.
                        withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = true }
                        highlightTask?.cancel()
                        highlightTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = false }
                        }
                        Task { @MainActor in
                            // Use smooth transition from current hardware brightness to slider value.
                            BrightnessService.shared.setBrightnessSmooth(localBrightness, for: display)
                            updateDDCStatus()
                        }
                        lastDDCWrite = Date()
                    }
                }
                .accessibilityLabel("Display brightness")
                .accessibilityValue("\(Int(localBrightness))%")
                .help("Drag to adjust brightness")
                .onChange(of: localBrightness) { _, newValue in
                    guard isDragging else { return }
                    // Apply immediately — the service chooses software or DDC internally.
                    // For DDC displays, throttle to ~100ms to avoid flooding the I2C bus.
                    // `ddcStatus == nil` means "not probed yet"; assume DDC in that case,
                    // otherwise the very first drag floods the bus with unthrottled writes.
                    let isDDC = ddcStatus != false
                    let now = Date()
                    if isDDC && now.timeIntervalSince(lastDDCWrite) < 0.1 {
                        // Too soon for another DDC write; the drag-end handler will flush the final value.
                        display.brightness = newValue
                        return
                    }
                    lastDDCWrite = now
                    display.brightness = newValue
                    Task { @MainActor in
                        await BrightnessService.shared.setBrightness(newValue, for: display)
                    }
                }

                Image(systemName: "sun.max")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                let brightnessLabel: String = {
                    if ddcStatus == false { return "Software \(Int(localBrightness))%" }
                    return "\(Int(localBrightness))%"
                }()
                Text(brightnessLabel)
                    .font(.caption)
                    .foregroundColor(valueHighlighted ? .accentColor : .secondary)
                    .frame(width: 52, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            // The cached value is only refreshed on display-configuration changes, so a
            // brightness set from System Settings, the native brightness keys or the
            // ambient-light sensor would otherwise show up as a stale slider.
            if display.isBuiltin {
                await BrightnessService.shared.refreshBrightness(for: display)
            }
            localBrightness = display.brightness
            updateDDCStatus()

            // Keep following external changes while the panel is visible. The task is
            // cancelled when MenuBarExtra tears this content down, so this costs nothing
            // while the menu is closed. DisplayServices reads are microsecond-level.
            guard display.isBuiltin else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, !isDragging else { continue }
                await BrightnessService.shared.refreshBrightness(for: display)
            }
        }
        .onChange(of: display.brightness) { _, newValue in
            if !isDragging && abs(newValue - localBrightness) >= 1 {
                localBrightness = newValue
            }
        }
    }

    private func updateDDCStatus() {
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double = 50
    @State private var isDragging: Bool = false
    /// Throttle DDC writes during drag to ~100ms intervals.
    @State private var lastDDCWrite: Date = .distantPast

    private var averageBrightness: Double {
        guard !displays.isEmpty else { return 50 }
        return displays.map(\.brightness).reduce(0, +) / Double(displays.count)
    }

    /// True if any display in the group may use DDC (so we apply throttle).
    /// `isDDCAvailable` returns nil before the first probe; assume DDC until proven otherwise.
    private var anyDDC: Bool {
        displays.contains { BrightnessService.shared.isDDCAvailable(for: $0.displayID) != false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Brightness (Combined)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(combinedBrightness))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Slider(value: $combinedBrightness, in: 5...100, step: 1) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag ended — flush final value to all displays with smooth transition.
                        Task { @MainActor in
                            for display in displays {
                                BrightnessService.shared.setBrightnessSmooth(combinedBrightness, for: display)
                            }
                        }
                        lastDDCWrite = Date()
                    }
                }
                .accessibilityLabel("Combined brightness")
                .accessibilityValue("\(Int(combinedBrightness))%")
                .onChange(of: combinedBrightness) { _, newValue in
                    guard isDragging else { return }
                    let now = Date()
                    if anyDDC && now.timeIntervalSince(lastDDCWrite) < 0.1 {
                        // Throttle DDC — update model only; drag-end flushes final value.
                        for display in displays { display.brightness = newValue }
                        return
                    }
                    lastDDCWrite = now
                    Task { @MainActor in
                        for display in displays {
                            display.brightness = newValue
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    }
                }

                Image(systemName: "sun.max")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task(id: displays.map(\.displayID)) {
            // Seed from the cached values, then re-read every display: the cache is only
            // invalidated by display-configuration changes, not by a brightness change
            // made from System Settings, the native keys or the monitor's own buttons.
            combinedBrightness = averageBrightness
            await refreshAll()
            combinedBrightness = averageBrightness

            // Follow changes while the panel is visible. The task dies with the
            // MenuBarExtra content, so this costs nothing when the menu is closed.
            // 1 s is enough here: DDC reads are cached for 5 s per VCP code.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !isDragging else { continue }
                await refreshAll()
                if !isDragging { combinedBrightness = averageBrightness }
            }
        }
        .onReceive(Publishers.MergeMany(displays.map(\.$brightness))) { _ in
            // Follow individual sliders and polled hardware values immediately;
            // never fight the user while the combined slider itself is being dragged.
            if !isDragging {
                combinedBrightness = averageBrightness
            }
        }
    }

    private func refreshAll() async {
        for display in displays {
            await BrightnessService.shared.refreshBrightness(for: display)
        }
    }
}
