import SwiftUI

/// Per-display HiDPI toggle.
///
/// Two mechanisms can provide HiDPI, and the row has to report the one that is
/// actually in effect:
///
/// * **macOS already offers HiDPI modes** for the display (every 4K+ panel does).
///   The state is then "is the current mode HiDPI", and toggling switches between the
///   HiDPI and non-HiDPI mode of the *same logical resolution* — the resolution the user
///   picked never changes, and nothing is written to disk.
/// * **The display has no HiDPI mode at all** (e.g. a 1440p panel). Only then does the
///   plist override make sense, and the row reports its ownership: an override written by
///   another tool (e.g. BetterDisplay) is labelled as such and never modified or deleted.
///
/// Reporting the plist's existence as "HiDPI Mode" was wrong for the first case: a display
/// running a HiDPI resolution showed as disabled, and enabling it wrote a redundant
/// override whose mode re-enumeration could drag the display onto a different resolution.
struct HiDPIRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject private var displayManager: DisplayManager
    @State private var isHovered = false
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var overrideState: HiDPIService.OverrideState = .none

    // MARK: - State

    /// True when macOS itself provides HiDPI modes for this display, i.e. the plist
    /// override path is neither needed nor wanted.
    private var nativeHiDPIAvailable: Bool {
        display.availableModes.contains { $0.isHiDPI }
    }

    private var currentMode: DisplayMode? { display.currentDisplayMode }

    private var isHiDPIOn: Bool {
        if nativeHiDPIAvailable { return currentMode?.isHiDPI == true }
        return overrideState != .none
    }

    private var isManagedByOther: Bool {
        !nativeHiDPIAvailable && overrideState == .managedByOther
    }

    /// The same logical resolution at the other scale factor, e.g. 2560×1440 ↔ 2560×1440
    /// HiDPI. Switching to it is what "turn HiDPI on/off" means for a display whose HiDPI
    /// modes come from macOS.
    private var counterpartMode: DisplayMode? {
        guard let current = currentMode else { return nil }
        return display.availableModes.first {
            $0.width == current.width &&
            $0.height == current.height &&
            $0.isHiDPI != current.isHiDPI
        }
    }

    private var canToggle: Bool {
        nativeHiDPIAvailable ? counterpartMode != nil : !isManagedByOther
    }

    /// An override this app wrote earlier for a display that no longer needs one. Left on
    /// disk it still adds scaled modes the next time the display is reconnected, which is
    /// how enabling HiDPI used to drag the display onto a different resolution.
    private var hasRedundantOverride: Bool {
        nativeHiDPIAvailable && overrideState == .managedByNunbit
    }

    private var subtitle: String {
        if nativeHiDPIAvailable {
            if counterpartMode == nil { return "No HiDPI mode at this resolution" }
            let base = isHiDPIOn ? "Provided by macOS" : "Available at this resolution"
            return hasRedundantOverride ? "\(base) · redundant override installed" : base
        }
        if isManagedByOther { return "Managed by another app" }
        return isHiDPIOn ? "Administrator override" : "Requires administrator privileges"
    }

    var body: some View {
        if display.isBuiltin {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MenuItemIcon(systemName: "sparkles", color: .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HiDPI Mode")
                            .font(.body)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else if isHiDPIOn {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(isHovered ? 0.06 : 0))
                .contentShape(Rectangle())
                .onTapGesture {
                    // Another app owns the override: leave it alone. Also nothing to do
                    // when the resolution in use has no counterpart at the other scale.
                    guard !isLoading, canToggle else { return }
                    toggle()
                }
                .onHover { isHovered = $0 }
                .help(canToggle
                      ? "Switch this resolution between normal and HiDPI scaling"
                      : subtitle)
                .contextMenu {
                    if hasRedundantOverride {
                        Button("Remove Nunbit's Redundant Override") {
                            removeRedundantOverride()
                        }
                    }
                }
            }
            .onAppear { refreshState() }
            .alert("HiDPI Operation Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let msg = errorMessage {
                    Text(msg)
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func refreshState() {
        overrideState = HiDPIService.shared.overrideState(
            vendor: display.vendorNumber,
            product: display.modelNumber
        )
    }

    @MainActor
    private func toggle() {
        if nativeHiDPIAvailable {
            switchScale()
        } else {
            togglePlistOverride()
        }
    }

    /// macOS-provided HiDPI: switch to the counterpart mode of the current logical
    /// resolution. The resolution the user chose is preserved, so nothing "jumps".
    @MainActor
    private func switchScale() {
        guard let target = counterpartMode else { return }
        isLoading = true
        let displayID = display.displayID
        Task { @MainActor in
            let ok = await ResolutionService.shared.setDisplayMode(target, for: displayID)
            if ok {
                try? await Task.sleep(nanoseconds: 300_000_000)
                // Report the mode the display actually ended up in, never the request.
                let applied = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: displayID)
                }.value
                display.currentDisplayMode = applied
                HiDPIService.shared.refreshModes(for: display)
            } else {
                errorMessage = "Could not switch to \(target.resolutionString) HiDPI. Please try again."
            }
            isLoading = false
        }
    }

    /// Deletes an override this app wrote for a display that gets HiDPI from macOS.
    /// Only ever touches Nunbit's own file (ownership is recorded), and asks for
    /// administrator privileges because the override lives in /Library/Displays.
    @MainActor
    private func removeRedundantOverride() {
        isLoading = true
        Task {
            let err = await HiDPIService.shared.disableHiDPI(
                for: display.displayID,
                vendor: display.vendorNumber,
                product: display.modelNumber
            )
            isLoading = false
            if let err {
                errorMessage = err
            } else {
                refreshState()
            }
        }
    }

    /// No HiDPI mode exists on this display: fall back to the plist override, which needs
    /// administrator privileges and takes effect after the display is reconnected.
    @MainActor
    private func togglePlistOverride() {
        isLoading = true
        if isHiDPIOn {
            Task {
                let err = await HiDPIService.shared.disableHiDPI(
                    for: display.displayID,
                    vendor: display.vendorNumber,
                    product: display.modelNumber
                )
                isLoading = false
                if let err {
                    errorMessage = err
                } else {
                    refreshState()
                }
            }
        } else {
            Task {
                // Use the highest available mode as native resolution,
                // not display.pixelWidth which is the CURRENT resolution
                let (nativeW, nativeH) = display.nativeResolution
                let err = await HiDPIService.shared.enableHiDPI(
                    for: display.displayID,
                    vendor: display.vendorNumber,
                    product: display.modelNumber,
                    nativeWidth: nativeW,
                    nativeHeight: nativeH
                )
                isLoading = false
                if let err {
                    errorMessage = err
                } else {
                    refreshState()
                    HiDPIService.shared.refreshModes(for: display)
                }
            }
        }
    }
}
