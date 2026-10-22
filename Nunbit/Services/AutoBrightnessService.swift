import AppKit
import Foundation
import IOKit
import CoreGraphics

// CoreDisplay private API — reads the user-set brightness of a display (0.0–1.0).
// Loaded via dlsym at runtime to avoid linking against the private CoreDisplay framework.
private let _CoreDisplay_GetBrightness: (@convention(c) (CGDirectDisplayID) -> Double)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Double).self)
}()

/// Reads the built-in display's brightness (which macOS auto-adjusts based on ambient light)
/// and syncs it to external displays. This avoids needing Intel-only LMU hardware access.
@MainActor
final class AutoBrightnessService: ObservableObject, @unchecked Sendable {
    static let shared = AutoBrightnessService()
    private init() {
        loadPrefs()

        // The service lives for the whole app lifetime, so it has to notice display
        // changes itself. The menu section is hidden when there is no source or target,
        // and polling must stop then restart when a display is connected again.
        displayObserver = NotificationCenter.default.addObserver(
            forName: .nunbitDisplaysDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluatePolling() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluatePolling() }
        }
    }

    // MARK: - State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                reevaluatePolling()
            } else {
                stopPolling()
            }
            savePrefs()
        }
    }

    /// Multiplier 0.5–1.5. Applied to builtin brightness when syncing to external displays.
    @Published var sensitivity: Double = 1.0 {
        didSet { savePrefs() }
    }

    /// Last builtin brightness reading (0.0–1.0). 0 = unavailable / no builtin display.
    @Published private(set) var builtinBrightness: Double = 0
    private var lastAppliedBrightness: Double = -1

    /// Set to true after the first poll attempt completes (success or failure).
    /// Used by the UI to distinguish "not polled yet" from "no builtin display found".
    @Published private(set) var hasPolled: Bool = false

    /// Physical external displays the last sync pass targeted. 0 means there is nothing to
    /// sync to — the panel says so instead of pretending it is working.
    @Published private(set) var syncTargetCount: Int = 0

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    /// Bumped whenever polling starts or stops. A loop that is winding down can then tell
    /// whether it is still the current poller before clearing the task or restarting.
    private var pollingGeneration: Int = 0
    private let pollingInterval: TimeInterval = 2.0  // seconds

    private var displayObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Launch

    /// Resolves the singleton at launch so a persisted "on" starts polling even when the
    /// user never opens the Auto Brightness section. `MenuBarExtra` content is built
    /// lazily, and relying on that section is the same failure mode as wake recovery:
    /// the feature silently did nothing after a relaunch until the panel was opened.
    func activateAtLaunch() {
        refreshBuiltinBrightnessOnce()
        reevaluatePolling()
    }

    /// One-off built-in brightness read, used while polling is off (or before the first
    /// poll) so the panel can show the current value.
    func refreshBuiltinBrightnessOnce() {
        // Keep the target count fresh even while polling is off: the panel shows it
        // whenever the section is visible, not only after the toggle is turned on.
        let context = pollingContext()
        if syncTargetCount != context.targetCount {
            syncTargetCount = context.targetCount
        }

        Task.detached { [weak self] in
            guard let self else { return }
            let value = self.readBuiltinBrightness()
            await MainActor.run {
                self.builtinBrightness = value ?? 0
                self.hasPolled = true
            }
        }
    }

    private nonisolated static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - Builtin Brightness

    /// Reads the current brightness of the builtin display.
    /// Returns a value in 0.0–1.0, or nil if no builtin display is found.
    /// Safe to call from a background thread.
    ///
    /// `builtinID` is passed by the polling loop, which already resolved it on the main
    /// actor, so each poll avoids a second pair of `CGGetActiveDisplayList` calls.
    nonisolated func readBuiltinBrightness(builtinID: CGDirectDisplayID? = nil) -> Double? {
        guard let builtinID = builtinID ?? Self.builtinDisplayID() else { return nil }

        // DisplayServices first: on macOS 26 CoreDisplay_Display_GetUserBrightness has been
        // observed returning a stale 1.0 while DisplayServices reports the real panel value.
        if let value = DisplayServicesBrightness.get(builtinID) {
            return Double(value)
        }

        // Fallback: CoreDisplay private API.
        let value = _CoreDisplay_GetBrightness?(builtinID) ?? 0
        if value > 0 {
            return min(1.0, max(0.0, value))
        }

        // Fallback: IODisplayGetFloatParameter via IOKit service matching
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            var floatValue: Float = 0
            let kr = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &floatValue)
            if kr == KERN_SUCCESS && floatValue > 0 {
                return min(1.0, max(0.0, Double(floatValue)))
            }
        }

        return nil
    }

    // MARK: - Polling

    private struct PollingContext {
        let builtinDisplayID: CGDirectDisplayID?
        let targetCount: Int
        var canPoll: Bool { builtinDisplayID != nil && targetCount > 0 }
    }

    /// The source is an active built-in panel (it carries the ambient-light sensor); the
    /// targets are physical external displays. Virtual displays have no backlight.
    @MainActor
    private func pollingContext() -> PollingContext {
        let displays = DisplayManagerAccessor.shared.displays
        let builtinID = displays.first {
            $0.isBuiltin && CGDisplayIsActive($0.displayID) != 0 && CGDisplayIsAsleep($0.displayID) == 0
        }?.displayID

        let targetCount = displays.filter {
            !$0.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }.count
        return PollingContext(builtinDisplayID: builtinID, targetCount: targetCount)
    }

    /// Starts, keeps, or stops polling according to the current display configuration and
    /// the enabled flag. Called at launch, on toggle, and whenever displays change.
    func reevaluatePolling() {
        guard isEnabled, pollingContext().canPoll else {
            stopPolling()
            return
        }
        startPolling()
    }

    private func startPolling() {
        // Idempotent: a display notification must not create a second loop.
        guard pollingTask == nil else { return }

        // Evaluate every target on the first pass. The loop may have been stopped while no
        // external display was connected, so the last applied value says nothing about a
        // display that has just appeared.
        lastAppliedBrightness = -1

        pollingGeneration += 1
        let generation = pollingGeneration
        let interval = pollingInterval
        #if DEBUG
        NSLog("[AutoBrightness] polling started")
        #endif

        pollingTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Re-check every iteration: a display can disappear without a notification
                // reaching us in time, and there is no point reading the panel then.
                let context = await MainActor.run(body: { self.pollingContext() })
                guard context.canPoll, let builtinID = context.builtinDisplayID else { break }

                let brightness = self.readBuiltinBrightness(builtinID: builtinID)
                await self.applyBrightness(builtin: brightness)

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            await MainActor.run { self.finishPolling(generation: generation) }
        }
    }

    @MainActor
    private func finishPolling(generation: Int) {
        // A newer start/stop already owns polling; do not clobber it.
        guard pollingGeneration == generation else { return }
        pollingTask = nil
        // A target may have appeared while this loop was winding down.
        reevaluatePolling()
    }

    private func stopPolling() {
        // Repeated display notifications call this while polling is already stopped;
        // do not bump the generation for a loop that does not exist.
        guard pollingTask != nil else { return }
        pollingGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        #if DEBUG
        NSLog("[AutoBrightness] polling stopped")
        #endif
    }

    @MainActor
    private func applyBrightness(builtin: Double?) async {
        // Publish only meaningful changes: this runs every 2 s and the panel observing it
        // would otherwise re-render on every identical poll.
        let reading = builtin ?? 0
        if abs(builtinBrightness - reading) >= 0.005 {
            builtinBrightness = reading
        }
        hasPolled = true

        // Only sync to physical external displays: the built-in panel drives the reading,
        // and a virtual display has no backlight to adjust. Report the count so the panel
        // can say "nothing to sync to" instead of implying it is working.
        let targets = DisplayManagerAccessor.shared.displays.filter {
            !$0.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }
        if syncTargetCount != targets.count {
            syncTargetCount = targets.count
        }

        guard let builtin, builtin > 0 else { return }

        // Only apply if builtin brightness changed more than 2% since last application.
        guard abs(builtin - lastAppliedBrightness) >= 0.02 else { return }

        // Respect 30-second cooldown after a manual brightness adjustment.
        if let last = BrightnessService.shared.lastManualAdjustDate,
           Date().timeIntervalSince(last) < 30.0 {
            return
        }

        let targetPercentage = min(100.0, max(0.0, builtin * sensitivity * 100.0))
        for display in targets {
            let current = display.brightness
            if abs(current - targetPercentage) >= 2.0 {
                await BrightnessService.shared.setBrightness(targetPercentage, for: display, isAutoAdjust: true)
            }
        }
        lastAppliedBrightness = builtin
    }

    // MARK: - Persistence

    private let enabledKey = "fd.AutoBrightnessEnabled"
    private let sensitivityKey = "fd.AutoBrightnessSensitivity"

    private func loadPrefs() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        if UserDefaults.standard.object(forKey: sensitivityKey) != nil {
            sensitivity = UserDefaults.standard.double(forKey: sensitivityKey)
        }
    }

    private func savePrefs() {
        UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(sensitivity, forKey: sensitivityKey)
    }
}

// MARK: - Display Manager Accessor

/// Thin wrapper so AutoBrightnessService can reach displays without a direct EnvironmentObject.
@MainActor
final class DisplayManagerAccessor {
    static let shared = DisplayManagerAccessor()
    var displays: [DisplayInfo] = []
    private init() {}
}
