import SwiftUI
import Observation

/// Expandable "Image Adjustment" section — 13 controls for software gamma/image adjustments.
/// Mirrors BetterDisplay's Image Adjustment panel.
///
/// Performance notes (why this file looks the way it does):
/// - The model is `@Observable`, not 13 `@State` properties on the container. Each row
///   reads only its own key path, so dragging one slider re-renders that row instead of
///   rebuilding all 13 rows and the whole MenuBarExtra `ScrollView`.
/// - Saved state is loaded in `init`, before the first render. Loading it in `onAppear`
///   forced a second full-body evaluation on every open.
/// - Nothing here writes display hardware when the view appears. Launch and every display
///   configuration change are already covered by
///   `DisplayManager.scheduleDisplayStateRestore` → `GammaService`; doing it again inside
///   the expansion animation was the cause of the visible stutter.
struct ImageAdjustmentView: View {
    /// Plain reference, not `@ObservedObject`: this view only needs the immutable display
    /// ID. Observing DisplayInfo rebuilt the whole panel whenever the brightness poll
    /// changed `display.brightness` (twice a second while the menu was open).
    let display: DisplayInfo

    @State private var model: ImageAdjustmentModel

    init(display: DisplayInfo) {
        self.display = display
        // Cheap UserDefaults read, done before the first render.
        _model = State(initialValue: ImageAdjustmentModel(
            saved: GammaService.shared.loadSavedState(for: display.displayID)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Group 1: Global adjustments ────────────────────────────────
            adjustRow(icon: "circle.righthalf.filled", label: "Contrast",         keyPath: \.contrast)
                .help("Adjust contrast")
            adjustRow(icon: "sparkle",                 label: "Gamma",            keyPath: \.gammaVal)
                .help("Adjust gamma")
            adjustRow(icon: "bolt.fill",               label: "Gain",             keyPath: \.gain)
                .help("Adjust gain")
            adjustRow(icon: "thermometer.medium",      label: "Color Temperature", keyPath: \.colorTemperature)
                .help("Adjust color temperature")
            QuantizationRow(model: model, commitAction: commitAdjustment)

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 2)

            // ── Group 2: Per-channel gamma ─────────────────────────────────
            adjustRow(icon: "r.circle", label: "Gamma R", keyPath: \.rGamma, accent: .red)
                .help("Adjust red gamma")
            adjustRow(icon: "g.circle", label: "Gamma G", keyPath: \.gGamma, accent: .green)
                .help("Adjust green gamma")
            adjustRow(icon: "b.circle", label: "Gamma B", keyPath: \.bGamma, accent: .blue)
                .help("Adjust blue gamma")

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 2)

            // ── Group 3: Per-channel gain ──────────────────────────────────
            adjustRow(icon: "r.circle.fill", label: "Gain R", keyPath: \.rGain, accent: .red)
                .help("Adjust red gain")
            adjustRow(icon: "g.circle.fill", label: "Gain G", keyPath: \.gGain, accent: .green)
                .help("Adjust green gain")
            adjustRow(icon: "b.circle.fill", label: "Gain B", keyPath: \.bGain, accent: .blue)
                .help("Adjust blue gain")

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 2)

            // ── HDR warning ────────────────────────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                Text("Adjustments may affect HDR content!")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // ── Action buttons ─────────────────────────────────────────────
            HStack(spacing: 8) {
                actionButton(
                    title: "Invert Colors",
                    systemImage: "circle.lefthalf.filled",
                    isActive: model.isInverted
                ) {
                    model.isInverted.toggle()
                    commitAdjustment()
                }
                .help("Invert display colors (similar to night mode)")

                actionButton(
                    title: model.isPaused ? "Resume Adjustments" : "Pause Adjustments",
                    systemImage: model.isPaused ? "play.circle" : "pause.circle",
                    isActive: model.isPaused
                ) {
                    model.isPaused.toggle()
                    if model.isPaused {
                        GammaService.shared.applyIdentity(for: display.displayID)
                    } else {
                        commitAdjustment()
                    }
                }
                .help("Temporarily disable color adjustments and restore the original image")

                actionButton(
                    title: "Reset All",
                    systemImage: "arrow.counterclockwise",
                    isActive: false
                ) {
                    resetAll()
                }
                .help("Reset all color adjustments to defaults")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onDisappear {
            // MenuBarExtra tears its content down on every panel close, so this runs far
            // more often than "the section was collapsed". It must therefore only persist
            // state and never touch display hardware: resetting here used to wipe the
            // ColorSync profile override installed by ColorProfileService and the
            // software-brightness dimming applied by BrightnessService.
            if model.isAtDefaults {
                // At defaults the display already shows the neutral transfer function (the
                // last commit applied an identity adjustment), so there is nothing to
                // restore — only the persisted state needs clearing.
                GammaService.shared.clearSavedState(for: display.displayID)
            } else {
                GammaService.shared.saveState(model.adjustment, for: display.displayID)
            }
        }
    }

    // MARK: - Row builder

    private func adjustRow(
        icon: String,
        label: String,
        keyPath: ReferenceWritableKeyPath<ImageAdjustmentModel, Double>,
        accent: Color = .blue
    ) -> some View {
        AdjustRow(
            icon: icon,
            label: label,
            accent: accent,
            model: model,
            keyPath: keyPath,
            commitAction: commitAdjustment
        )
    }

    // MARK: - Action button builder

    private func actionButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08))
            .foregroundColor(isActive ? .blue : .primary)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func commitAdjustment() {
        guard !model.isPaused else { return }
        GammaService.shared.apply(model.adjustment, for: display.displayID)
    }

    @MainActor
    private func resetAll() {
        model.reset()
        GammaService.shared.clearSavedState(for: display.displayID)
        // Reset the gamma transfer table only: the ICC profile override belongs to
        // ColorProfileService, not to image adjustment, so it must survive this.
        GammaService.shared.resetSingleDisplay(display.displayID)
        // Resetting gamma must not un-dim a display running on the software brightness
        // fallback — re-assert the stored factor if there is one.
        BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
    }
}

// MARK: - Model

/// Single source of truth for the panel. `@Observable` gives per-property change
/// tracking, so a row that only reads `contrast` is not invalidated by a `gain` change.
@Observable
final class ImageAdjustmentModel {
    var contrast: Double = 0
    var gammaVal: Double = 0
    var gain: Double = 0
    var colorTemperature: Double = 0
    var quantLevels: Double = 256
    var rGamma: Double = 0
    var gGamma: Double = 0
    var bGamma: Double = 0
    var rGain: Double = 0
    var gGain: Double = 0
    var bGain: Double = 0
    var isInverted: Bool = false
    var isPaused: Bool = false

    init(saved: GammaAdjustment?) {
        guard let s = saved else { return }
        contrast = s.contrast
        gammaVal = s.gammaVal
        gain = s.gain
        colorTemperature = s.colorTemperature
        rGamma = s.rGamma
        gGamma = s.gGamma
        bGamma = s.bGamma
        rGain = s.rGain
        gGain = s.gGain
        bGain = s.bGain
        quantLevels = Double(s.quantizationLevels)
        isInverted = s.isInverted
        isPaused = s.isPaused
    }

    var adjustment: GammaAdjustment {
        GammaAdjustment(
            contrast: contrast,
            gammaVal: gammaVal,
            gain: gain,
            colorTemperature: colorTemperature,
            rGamma: rGamma, gGamma: gGamma, bGamma: bGamma,
            rGain: rGain,   gGain: gGain,   bGain: bGain,
            quantizationLevels: Int(quantLevels),
            isInverted: isInverted,
            // Commit only runs while unpaused, so this is false there; onDisappear needs
            // the real value so a paused adjustment stays paused across menu opens.
            isPaused: isPaused
        )
    }

    var isAtDefaults: Bool {
        contrast == 0 && gammaVal == 0 && gain == 0 &&
            colorTemperature == 0 && rGamma == 0 && gGamma == 0 && bGamma == 0 &&
            rGain == 0 && gGain == 0 && bGain == 0 && !isInverted &&
            quantLevels == 256
    }

    func reset() {
        contrast = 0
        gammaVal = 0
        gain = 0
        colorTemperature = 0
        rGamma = 0; gGamma = 0; bGamma = 0
        rGain = 0;  gGain = 0;  bGain = 0
        quantLevels = 256
        isInverted = false
        isPaused = false
    }
}

// MARK: - Rows

private struct AdjustRow: View {
    let icon: String
    let label: String
    let accent: Color
    let model: ImageAdjustmentModel
    let keyPath: ReferenceWritableKeyPath<ImageAdjustmentModel, Double>
    let commitAction: () -> Void

    @State private var highlighted: Bool = false

    /// Reads through the key path so Observation registers a dependency on exactly this
    /// property, not on the whole model.
    private var valueBinding: Binding<Double> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }

    private func percentLabel(_ v: Double) -> String {
        let sign = v > 0 ? "+" : ""
        return "\(sign)\(Int(v))%"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(accent)
                .frame(width: 18)
                .font(.caption)

            Text(label)
                .font(.caption)
                .frame(width: 72, alignment: .leading)

            Slider(value: valueBinding, in: -100...100, step: 1) { editing in
                if !editing {
                    commitAction()
                    withAnimation(.easeOut(duration: 0.3)) { highlighted = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        withAnimation(.easeOut(duration: 0.3)) { highlighted = false }
                    }
                }
            }
            .tint(accent)

            Text(percentLabel(model[keyPath: keyPath]))
                .font(.caption)
                .foregroundColor(highlighted ? accent : .secondary)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

private struct QuantizationRow: View {
    let model: ImageAdjustmentModel
    let commitAction: () -> Void

    private var valueBinding: Binding<Double> {
        Binding(
            get: { model.quantLevels },
            set: { model.quantLevels = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundColor(.blue)
                .frame(width: 18)
                .font(.caption)

            Text("Quantization")
                .font(.caption)
                .frame(width: 72, alignment: .leading)

            Slider(value: valueBinding, in: 2...256, step: 1) { editing in
                // Commit on release only: the editing-changed closure fires at BOTH ends,
                // so committing unconditionally wrote the gamma table twice per drag
                // (once with the pre-drag value).
                if !editing { commitAction() }
            }
            .help("Adjust quantization level")

            Text(model.quantLevels >= 255 ? "∞" : "\(Int(model.quantLevels))")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
