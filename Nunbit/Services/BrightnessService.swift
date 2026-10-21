import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// MARK: - BrightnessAnimator

/// Manages smooth brightness transitions for a single display.
/// Cancels any in-progress animation when a new one starts, so rapid presses stay responsive.
/// All methods must be called on the main thread.
final class BrightnessAnimator: @unchecked Sendable {
    private var timer: Timer?
    private var currentStep: Int = 0
    private var totalSteps: Int = 0
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var stepHandler: ((Double, Bool) -> Void)?

    /// Cancel any running animation immediately.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Animate from `from` to `to` over `duration` seconds using `steps` discrete steps.
    /// `handler(value, isLast)` is called once per step on the main thread.
    /// Calling this cancels any previously running animation.
    func animate(
        from: Double,
        to: Double,
        steps: Int,
        duration: TimeInterval,
        handler: @escaping (Double, Bool) -> Void
    ) {
        cancel()

        // If from ≈ to, no animation needed — just apply final value.
        guard abs(to - from) > 0.001, steps > 1 else {
            handler(to, true)
            return
        }

        let clampedSteps = max(2, steps)
        currentStep = 0
        totalSteps = clampedSteps
        startValue = from
        targetValue = to
        stepHandler = handler
        let interval = duration / Double(clampedSteps)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.currentStep += 1
            let progress = Double(self.currentStep) / Double(self.totalSteps)
            // Ease-out curve: smoother deceleration at the end
            let eased = 1.0 - pow(1.0 - progress, 2.0)
            let value = self.startValue + (self.targetValue - self.startValue) * eased
            let isLast = self.currentStep >= self.totalSteps
            if isLast {
                t.invalidate()
                self.timer = nil
            }
            // Always pass the exact target on the last step to avoid floating-point drift.
            self.stepHandler?(isLast ? self.targetValue : value, isLast)
            if isLast { self.stepHandler = nil }
        }
    }
}

// MARK: - BrightnessService

final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}

    private let queue = DispatchQueue(label: "com.jseook11.brightness", qos: .userInitiated)

    // MARK: - Per-display Animators (main thread only)

    /// One animator per display. Accessed only on the main thread.
    private var animators: [CGDirectDisplayID: BrightnessAnimator] = [:]

    private func animator(for displayID: CGDirectDisplayID) -> BrightnessAnimator {
        if let existing = animators[displayID] { return existing }
        let a = BrightnessAnimator()
        animators[displayID] = a
        return a
    }

    /// Cancel any running brightness animation for a display.
    /// Call this before starting an instant (non-animated) change.
    @MainActor
    func cancelAnimation(for displayID: CGDirectDisplayID) {
        animators[displayID]?.cancel()
    }

    // MARK: - Manual Adjust Cooldown

    /// Set when the user manually adjusts brightness; auto-brightness skips updates for 30 s.
    private(set) var lastManualAdjustDate: Date? = nil
    private let manualAdjustLock = NSLock()

    // MARK: - Software Brightness Factors

    /// Stores the current software brightness factor per display (0.01–1.0).
    private var softwareBrightnessFactors: [CGDirectDisplayID: Double] = [:]
    private let softwareBrightnessLock = NSLock()

    private func softBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        PerDisplayStore.key("fd.softBrightness_", for: displayID)
    }

    private func saveSoftwareBrightness(factor: Double, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(factor, forKey: softBrightnessKey(for: displayID))
    }

    private func loadSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = softBrightnessKey(for: displayID)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Returns the current software brightness factor for a display, or nil if not set.
    func currentSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
    }

    // MARK: - DDC Availability Cache

    /// Per-display DDC health.
    ///
    /// Deliberately *not* a sticky Bool: one failed write (monitor asleep, input switch, a
    /// fade that raced a sleep) must not pin a display to gamma dimming forever. Failures
    /// are time-stamped, so the very next explicit adjustment retries hardware DDC while
    /// still dimming immediately through the software fallback.
    private struct DDCHealth {
        /// A DDC read or write has succeeded at least once for this display.
        var everSucceeded: Bool = false
        /// Consecutive DDC write failures since the last success.
        var consecutiveFailures: Int = 0
        /// Timestamp of the most recent DDC write failure; nil when the last attempt
        /// succeeded (or when none has been made yet).
        var lastFailure: Date?

        /// A display that has never answered DDC and keeps failing is treated as
        /// software-only: we stop probing it on every animation step and on every refresh,
        /// but an explicit adjustment still retries once per `ddcReprobeInterval` so a
        /// monitor that appears later (input switch, wake) can still recover.
        var isSoftwareOnly: Bool { !everSucceeded && consecutiveFailures >= 3 }
    }

    private var ddcHealth: [CGDirectDisplayID: DDCHealth] = [:]
    private let ddcHealthLock = NSLock()

    /// Bounded retry window for displays classified as software-only, and for re-probing
    /// a display whose last DDC write failed.
    private static let ddcReprobeInterval: TimeInterval = 20

    /// Per-display DDC max brightness value reported by the monitor.
    /// Used to denormalize 0–100% into the display's native DDC range.
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]

    // MARK: - Public API

    /// Synchronous brightness (0–100) for the built-in display, used to seed the UI before
    /// its first render so the slider does not flash its default value. A DisplayServices
    /// read is microsecond-level, so running it on the main thread is safe.
    func currentBuiltinBrightnessPercent(for displayID: CGDirectDisplayID) -> Double? {
        guard CGDisplayIsBuiltin(displayID) != 0,
              let value = DisplayServicesBrightness.get(displayID) else { return nil }
        return Double(value) * 100.0
    }

    @MainActor
    func refreshBrightness(for display: DisplayInfo) async {
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        if isBuiltin {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.getInternalBrightness())
                }
            }
            if let b = brightness {
                display.brightness = b
            }
        } else {
            // Skip the async DDC probe only while a failure is still fresh. After
            // `ddcReprobeInterval` we probe again, so a monitor that comes back (input
            // switch, wake) is re-detected instead of being stuck in software mode.
            let skipProbe: Bool = ddcHealthLock.withLock {
                guard let lastFailure = ddcHealth[displayID]?.lastFailure else { return false }
                return Date().timeIntervalSince(lastFailure) < Self.ddcReprobeInterval
            }
            if skipProbe {
                // Can't read brightness from gamma tables meaningfully; leave value as-is
                return
            }

            DDCService.shared.readAsync(
                displayID: displayID,
                command: DDCService.brightnessVCP
            ) { [weak self] result in
                // DDCService calls this back on its own queue; hop to the main actor
                // before touching MainActor-isolated state.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result = result, result.max > 0 {
                        let brightness = Double(result.current) / Double(result.max) * 100.0
                        self.ddcHealthLock.withLock {
                            self.ddcMaxBrightness[displayID] = result.max
                        }
                        // A usable Get VCP reply proves the DDC channel is alive again.
                        self.recordDDCSuccess(for: displayID)
                        display.brightness = brightness
                    } else {
                        // No usable Get VCP reply. Some monitors accept Set VCP (so
                        // brightness writes work) but never answer reads, so do NOT mark
                        // DDC unavailable here — write success/failure decides that.
                        // The write path assumes a 0–100 range when max is unknown.
                        #if DEBUG
                        print("[BrightnessService] no usable DDC read for display \(displayID); assuming 0–100 range")
                        #endif
                    }
                }
            }
        }
    }

    @MainActor
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) async {
        let clamped = max(0.0, min(100.0, brightness))
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        // Record manual adjust time so auto-brightness can honour the cooldown period.
        if !isAutoAdjust {
            manualAdjustLock.withLock { lastManualAdjustDate = Date() }
            // Persist the user's intent. Some monitors never answer DDC reads, so the
            // hardware value cannot be read back; without this the slider would restart
            // at 50% on every launch and jump on the first drag.
            SettingsService.shared.setBrightness(clamped, for: displayID)
        }

        if isBuiltin {
            let value = Float(clamped / 100.0)
            display.brightness = clamped
            queue.async { [weak self] in
                self?.setInternalBrightness(value)
            }
        } else {
            let attemptDDC = shouldAttemptDDC(for: displayID)

            // If the previous DDC attempt failed, dim through gamma synchronously so the
            // change is visible immediately even though the retry below is asynchronous.
            if lastDDCAttemptFailed(for: displayID) || !attemptDDC {
                setSoftwareBrightness(clamped, for: displayID)
            }

            // A display classified as software-only is still retried occasionally, but not
            // on every single change: a failing I2C write must not stall each drag.
            guard attemptDDC else { return }

            // Attempt the hardware write; on failure it falls back to gamma dimming.
            writeDDCBrightness(clamped, for: displayID)
        }
    }

    // MARK: - Smooth Brightness Transitions

    /// Animate brightness from the display's current value to `targetBrightness` smoothly.
    ///
    /// - For DDC displays: sends 5 DDC commands spaced ~40ms apart (200ms total).
    ///   DDC I2C commands are inherently slow (~40–50ms each), so 5 steps at 40ms intervals
    ///   fills the 200ms window without flooding the bus.
    /// - For software (gamma) brightness: 8 gamma table updates over 200ms give a visibly
    ///   smooth fade without perceptible frame drops.
    /// - For built-in displays: 8 IOKit writes over 200ms mirror the software path.
    ///
    /// Cancels any previously running animation for the same display, so rapid key presses
    /// always feel responsive — the animation re-targets from wherever it currently is.
    @MainActor
    func setBrightnessSmooth(
        _ targetBrightness: Double,
        for display: DisplayInfo,
        isAutoAdjust: Bool = false
    ) {
        let clamped = max(0.0, min(100.0, targetBrightness))
        let displayID = display.displayID
        let fromBrightness = display.brightness

        if !isAutoAdjust {
            manualAdjustLock.withLock { lastManualAdjustDate = Date() }
            SettingsService.shared.setBrightness(clamped, for: displayID)
        }

        let anim = animator(for: displayID)

        if display.isBuiltin {
            // Built-in: use IOKit — 8 steps over 200ms
            anim.animate(from: fromBrightness, to: clamped, steps: 8, duration: 0.20) { [weak self, weak display] value, _ in
                guard let self, let display else { return }
                display.brightness = value
                let floatVal = Float(value / 100.0)
                self.queue.async { self.setInternalBrightness(floatVal) }
            }
        } else {
            let attemptDDC = shouldAttemptDDC(for: displayID)

            if lastDDCAttemptFailed(for: displayID) || !attemptDDC {
                // Software (gamma) path: 8 steps over 200ms. Used while the last DDC
                // attempt is failing, so the drag always has an immediate visible effect.
                anim.animate(from: fromBrightness, to: clamped, steps: 8, duration: 0.20) { [weak self, weak display] value, isLast in
                    guard let self else { return }
                    display?.brightness = value
                    self.setSoftwareBrightness(value, for: displayID)
                    if isLast && attemptDDC {
                        // Retry hardware DDC once the drag settles: a transient failure
                        // (sleep, input switch) must not pin this display to software
                        // dimming. On success the software factor is cleared.
                        self.writeDDCBrightness(clamped, for: displayID)
                    }
                }
            } else {
                // DDC path: 5 steps over 200ms.
                // DDC I2C is slow (~40-50ms per command), so 5 steps at 40ms intervals
                // keeps the bus from overloading while giving smooth visible steps.
                anim.animate(from: fromBrightness, to: clamped, steps: 5, duration: 0.20) { [weak self, weak display] value, isLast in
                    guard let self else { return }
                    display?.brightness = value
                    // Only fall back to software dimming on the final step, so one dropped
                    // intermediate command does not dim the screen mid-drag.
                    self.writeDDCBrightness(value, for: displayID, applySoftwareFallback: isLast)
                }
            }
        }
    }

    // MARK: - Software Brightness (Gamma Table Fallback)

    /// Applies brightness via gamma table manipulation for displays where DDC is unavailable.
    /// Uses a linear ramp from 0 to `factor` so white level is dimmed while black stays black.
    /// brightness: 0–100 (percentage); never goes fully to 0 to avoid a completely black screen.
    ///
    /// If GammaService has an active adjustment for this display, it delegates to GammaService
    /// so the two do not overwrite each other's CGSetDisplayTransfer* call.
    func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(0.05, brightness / 100.0)
        if factor >= 1.0 {
            // No dimming needed: never persist a no-op factor, otherwise it could outlive
            // the DDC failure that created it and be resurrected after a restart.
            softwareBrightnessLock.withLock { _ = softwareBrightnessFactors.removeValue(forKey: displayID) }
            UserDefaults.standard.removeObject(forKey: softBrightnessKey(for: displayID))
        } else {
            softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = factor }
            saveSoftwareBrightness(factor: factor, for: displayID)
        }

        // If GammaService has an active adjustment, let it re-apply (it will incorporate the factor).
        if GammaService.shared.hasActiveAdjustment(for: displayID) {
            GammaService.shared.reapply(for: displayID)
            return
        }

        // No active gamma adjustment — write a plain dimmed ramp directly.
        let floatFactor = Float(factor)
        let tableSize: UInt32 = 256
        var red   = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var green = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var blue  = [CGGammaValue](repeating: 0, count: Int(tableSize))

        for i in 0..<Int(tableSize) {
            let v = CGGammaValue(Float(i) / Float(tableSize - 1) * floatFactor)
            red[i]   = v
            green[i] = v
            blue[i]  = v
        }

        let result = CGSetDisplayTransferByTable(displayID, tableSize, &red, &green, &blue)
        #if DEBUG
        if result != CGError.success {
            print("[BrightnessService] CGSetDisplayTransferByTable failed: \(result)")
        } else {
            print("[BrightnessService] software brightness set to \(Int(brightness))% for display \(displayID)")
        }
        #endif
    }

    /// Writes a plain identity gamma ramp for a display, removing any software dimming.
    /// Used by `clearSoftwareBrightness` when no colour adjustment is active.
    func resetSoftwareBrightness(for displayID: CGDirectDisplayID) {
        let size = 256
        let values = (0..<size).map { CGGammaValue($0) / CGGammaValue(size - 1) }
        var red = values
        var green = values
        var blue = values
        CGSetDisplayTransferByTable(displayID, UInt32(size), &red, &green, &blue)
    }

    /// Drops the software-brightness factor for a display and makes the screen reflect it.
    ///
    /// Called when a hardware DDC write succeeds again. Without this, one transient DDC
    /// failure leaves the panel permanently darker than the slider claims, because the DDC
    /// path never removed the gamma dimming. No-op when no factor is stored anywhere.
    func clearSoftwareBrightness(for displayID: CGDirectDisplayID) {
        let hadInMemory = softwareBrightnessLock.withLock {
            softwareBrightnessFactors.removeValue(forKey: displayID) != nil
        }
        let hadPersisted = UserDefaults.standard.object(forKey: softBrightnessKey(for: displayID)) != nil
        guard hadInMemory || hadPersisted else { return }
        UserDefaults.standard.removeObject(forKey: softBrightnessKey(for: displayID))

        // Re-apply the transfer function without the brightness factor: let GammaService own
        // the write when a colour adjustment is active, otherwise write an identity ramp.
        if GammaService.shared.hasActiveAdjustment(for: displayID) {
            GammaService.shared.reapply(for: displayID)
        } else {
            resetSoftwareBrightness(for: displayID)
        }
    }

    /// Returns whether DDC is available for the given display.
    /// nil means not yet determined (first use); false means the most recent DDC attempt
    /// failed, so the display is currently driven by the software fallback.
    func isDDCAvailable(for displayID: CGDirectDisplayID) -> Bool? {
        ddcHealthLock.withLock {
            guard let health = ddcHealth[displayID] else { return nil }
            return health.lastFailure == nil
        }
    }

    /// Clears DDC health and max brightness cache for a disconnected display.
    /// Call this when a display is removed so stale state cannot pollute a reconnect.
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcHealthLock.withLock {
            ddcHealth.removeValue(forKey: displayID)
            ddcMaxBrightness.removeValue(forKey: displayID)
        }
    }

    /// Re-applies the software brightness for a display after wake from sleep or hot-plug.
    /// Checks in-memory factor first; falls back to UserDefaults so restart is handled too.
    /// No-op if no saved factor < 1.0 exists.
    ///
    /// `clearSoftwareBrightness` removes both the in-memory and the persisted entry, so a
    /// factor cleared when DDC recovered cannot be resurrected here.
    func reapplySoftwareBrightnessIfNeeded(for display: DisplayInfo) {
        let displayID = display.displayID
        let inMemory = softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
        let factor = inMemory ?? loadSoftwareBrightness(for: displayID)
        guard let f = factor, f < 1.0 else { return }
        // Populate in-memory cache if loaded from disk
        if inMemory == nil {
            softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = f }
        }
        setSoftwareBrightness(f * 100.0, for: displayID)
    }

    // MARK: - DDC Health Bookkeeping

    /// Records that a DDC read or write succeeded for a display.
    private func recordDDCSuccess(for displayID: CGDirectDisplayID) {
        ddcHealthLock.withLock {
            var health = ddcHealth[displayID] ?? DDCHealth()
            health.everSucceeded = true
            health.consecutiveFailures = 0
            health.lastFailure = nil
            ddcHealth[displayID] = health
        }
    }

    /// Records a DDC write failure. The failure is time-stamped rather than latched, so the
    /// next explicit adjustment retries hardware DDC instead of falling back forever.
    private func recordDDCFailure(for displayID: CGDirectDisplayID) {
        ddcHealthLock.withLock {
            var health = ddcHealth[displayID] ?? DDCHealth()
            health.consecutiveFailures += 1
            health.lastFailure = Date()
            ddcHealth[displayID] = health
        }
    }

    /// True when the most recent DDC attempt for this display failed, i.e. the display is
    /// currently being dimmed in software.
    private func lastDDCAttemptFailed(for displayID: CGDirectDisplayID) -> Bool {
        ddcHealthLock.withLock { ddcHealth[displayID]?.lastFailure != nil }
    }

    /// Whether an explicit user adjustment should attempt a hardware DDC write now.
    /// Always true until a display has repeatedly failed without ever succeeding; such a
    /// display is retried at most once per `ddcReprobeInterval`, so a failing I2C write does
    /// not stall every drag while a late-appearing monitor can still recover.
    private func shouldAttemptDDC(for displayID: CGDirectDisplayID) -> Bool {
        ddcHealthLock.withLock {
            guard let health = ddcHealth[displayID], health.isSoftwareOnly else { return true }
            guard let lastFailure = health.lastFailure else { return true }
            return Date().timeIntervalSince(lastFailure) >= Self.ddcReprobeInterval
        }
    }

    /// Sends one hardware DDC brightness write and updates the per-display DDC health.
    ///
    /// On success the software-brightness factor is cleared, so a display that recovers from
    /// a transient DDC failure stops being dimmed twice.
    /// On failure the failure is recorded and, when `applySoftwareFallback` is true, the
    /// gamma fallback is applied so the slider still has a visible effect.
    private func writeDDCBrightness(
        _ brightness: Double,
        for displayID: CGDirectDisplayID,
        applySoftwareFallback: Bool = true
    ) {
        // Denormalize percentage to the display's native DDC range.
        // If max is unknown, default to 100 (safe for most monitors).
        let knownMax: UInt16 = ddcHealthLock.withLock { ddcMaxBrightness[displayID] ?? 100 }
        let ddcValue = UInt16((brightness / 100.0) * Double(knownMax))

        DDCService.shared.writeAsync(
            displayID: displayID,
            command: DDCService.brightnessVCP,
            value: ddcValue
        ) { [weak self] success in
            // DDCService calls this back on its own queue; hop to the main actor
            // before touching MainActor-isolated state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.recordDDCSuccess(for: displayID)
                    self.clearSoftwareBrightness(for: displayID)
                } else {
                    self.recordDDCFailure(for: displayID)
                    if applySoftwareFallback {
                        self.setSoftwareBrightness(brightness, for: displayID)
                        #if DEBUG
                        print("[BrightnessService] DDC write failed for display \(displayID), using software fallback")
                        #endif
                    }
                }
            }
        }
    }

    // MARK: - Internal Display (IODisplayGetFloatParameter)

    private static nonisolated(unsafe) let ioDisplayBrightnessKey = "brightness" as CFString

    /// The CGDirectDisplayID of the built-in display, if one is online.
    private func builtinDisplayID() -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        return (0..<Int(displayCount))
            .map({ displayIDs[$0] })
            .first(where: { CGDisplayIsBuiltin($0) != 0 })
    }

    /// Returns the io_service_t for the built-in display using CGDisplayIOServicePort.
    /// Falls back to iterating IODisplayConnect services if CGDisplayIOServicePort returns null.
    /// Caller does NOT need to release — CGDisplayIOServicePort returns a non-retained port.
    private func builtinIOService() -> io_service_t? {
        guard let builtinID = builtinDisplayID() else { return nil }

        // CGDisplayIOServicePort returns a non-retained service port (do not release)
        let servicePort = CGDisplayIOServicePort(builtinID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            return servicePort
        }

        return nil
    }

    private func getInternalBrightness() -> Double? {
        // Primary: DisplayServices. On macOS 26 CGDisplayIOServicePort returns 0 and there
        // are no IODisplayConnect services at all, so the IOKit paths below never reach
        // the panel; DisplayServices is the only working read on Apple Silicon.
        if let builtinID = builtinDisplayID(),
           let value = DisplayServicesBrightness.get(builtinID) {
            return Double(value) * 100.0
        }

        // Fallback: use CGDisplayIOServicePort to get the specific builtin display service
        if let servicePort = builtinIOService() {
            var value: Float = 0
            if IODisplayGetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }

        // Fallback: iterate IODisplayConnect but only accept services that
        // correspond to a built-in display (matched via CGDisplayIOServicePort cross-check).
        // Build set of known external service ports to exclude them.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // Skip services that are known external display ports
            guard !externalPorts.contains(service) else { continue }
            var value: Float = 0
            if IODisplayGetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }
        return nil
    }

    private func setInternalBrightness(_ value: Float) {
        // Primary: DisplayServices — see getInternalBrightness() for why IOKit is dead here.
        if let builtinID = builtinDisplayID(),
           DisplayServicesBrightness.set(value, for: builtinID) {
            #if DEBUG
            print("[BrightnessService] internal brightness set to \(value) via DisplayServices")
            #endif
            return
        }

        // Fallback: use CGDisplayIOServicePort to target only the builtin display service
        if let servicePort = builtinIOService() {
            if IODisplaySetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }

        // Fallback: iterate IODisplayConnect, skipping known external ports
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else {
            #if DEBUG
            print("[BrightnessService] setInternalBrightness: no builtin service responded")
            #endif
            return
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard !externalPorts.contains(service) else { continue }
            if IODisplaySetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }
        #if DEBUG
        print("[BrightnessService] setInternalBrightness: no builtin service responded")
        #endif
    }
}
