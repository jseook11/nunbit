import AppKit
import Foundation
import CoreGraphics

// Global C-compatible callback for display reconfiguration.
// Must be a top-level function (not a closure) to be used as a C function pointer.
private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()

    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .setMainFlag, .setModeFlag]
    guard !flags.intersection(relevant).isEmpty else { return }

    // Skip the begin-configuration notification; only act when the change is complete.
    // (beginConfigurationFlag is set at the start of a transaction; absence means it finished.)
    guard !flags.contains(.beginConfigurationFlag) else { return }

    Task { @MainActor in
        if flags.intersection([.addFlag, .removeFlag]).isEmpty {
            // Mode or main-display change: refresh mode info for existing displays only.
            manager.refreshExistingDisplayModes()
        } else {
            manager.refreshDisplays()
        }

        // Every completed configuration change discards the transfer tables of *all*
        // displays, so re-assert software brightness and gamma once WindowServer settles.
        manager.scheduleDisplayStateRestore()

        // Auto-rearrange only after structural changes (add/remove/mode).
        // Do NOT arrange on .setMainFlag: that would immediately undo a user's
        // "set as main" action and can create a callback feedback loop.
        let shouldArrange = !flags.intersection([.addFlag, .removeFlag, .setModeFlag]).isEmpty
        if shouldArrange {
            manager.scheduleAutoArrange()
        }
    }
}

@MainActor
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []

    // nonisolated(unsafe) allows deinit (which is nonisolated in Swift 6) to access this value.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?
    /// Same rationale as `callbackContext`: deinit is nonisolated and must remove it.
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    /// AppKit's screen-parameter notification, which also fires when a `CGVirtualDisplay`
    /// appears or disappears. The CoreGraphics reconfiguration callback *does* report those
    /// too (`.addFlag` / `.removeFlag`), but it arrives while the transaction is still
    /// committing; this one arrives after AppKit has reacted, which gives the state restore
    /// a second, later chance to land.
    nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?

    /// Work item used to debounce auto-arrange calls triggered by display config changes.
    private var autoArrangeWorkItem: DispatchWorkItem?
    /// Ensures the optional initial arrangement runs at most once per app launch.
    private var didScheduleInitialArrange = false
    /// Post-wake recovery pass, so a second wake cancels a still-pending first one.
    private var wakeRecoveryTask: Task<Void, Never>?
    /// Pending display-state restore passes, debounced so a burst of configuration
    /// callbacks (arrangement + add + mode switch) does not re-apply repeatedly.
    private var stateRestoreWorkItems: [DispatchWorkItem] = []

    /// Setting key for the opt-in HiDPI auto-enable path. Default off.
    nonisolated static let autoEnableHiDPIKey = "fd.hidpi.autoEnable"

    init() {
        refreshDisplays()
        setupReconfigCallback()
        setupWakeObserver()
        setupScreenParametersObserver()
    }

    deinit {
        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, ctx)
            Unmanaged<DisplayManager>.fromOpaque(ctx).release()
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Sleep / wake recovery

    /// Observes system wake here rather than through a closure wired up from the
    /// SwiftUI menu content: `MenuBarExtra` content is built lazily, so a login launch
    /// where the user never opens the menu used to leave wake recovery uninstalled.
    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleWakeRecovery()
            }
        }
    }

    /// Observes AppKit's screen-parameter notification so a virtual display appearing or
    /// disappearing also triggers a display-list refresh and a state restore.
    private func setupScreenParametersObserver() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplays()
            }
        }
    }

    /// Re-applies display state after the system wakes: re-enumerates displays, then
    /// re-applies software brightness, gamma and any saved custom resolution.
    /// The 2-second delay lets WindowServer settle before we touch transfer tables.
    func scheduleWakeRecovery() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }

            self.refreshDisplays()

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }

            self.restoreDisplayState()

            for display in self.displays {
                // Re-apply any custom resolution that macOS may have reset on wake
                ResolutionService.shared.reapplySavedModeIfNeeded(for: display.displayID)
            }
        }
    }

    // MARK: - Display state recovery after a configuration change

    /// Schedules a debounced re-apply of the per-display state that WindowServer throws
    /// away whenever the display configuration changes.
    ///
    /// The reset is not limited to the display that changed: creating or destroying a
    /// virtual display takes *every* other display's transfer table back to identity
    /// (measured on macOS 26 — a display at `lo=0.04 / hi=0.96` returns to `lo=0 / hi=1`).
    /// Nothing else restores it, so without this pass activating a virtual display left
    /// the monitor brighter than the user set it, until an unrelated view re-applied the
    /// adjustment by hand.
    ///
    /// Passes per change. The transfer table is reset by WindowServer itself, so a short
    /// visible blip is unavoidable; what these control is how quickly it ends. A write that
    /// lands while the transaction is still committing is silently discarded, so the first
    /// pass is early (measured: the reset lands ~0.2 s after the display appears) and the
    /// later ones guarantee the state comes back even if that first write was dropped.
    /// Re-applying is idempotent, so extra passes cost nothing visible.
    private static let stateRestoreDelays: [TimeInterval] = [0.05, 0.25, 1.2]

    func scheduleDisplayStateRestore() {
        stateRestoreWorkItems.forEach { $0.cancel() }
        stateRestoreWorkItems = Self.stateRestoreDelays.map { delay in
            let item = DispatchWorkItem { [weak self] in
                self?.restoreDisplayState()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    /// Re-applies software brightness and the gamma adjustment for every online display.
    /// Software brightness goes first: GammaService folds the factor into its formula,
    /// so it must be current before the transfer table is written.
    func restoreDisplayState() {
        for display in displays where display.isOnline {
            BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
            GammaService.shared.restoreAfterReconfiguration(for: display.displayID)
        }
    }

    func refreshDisplays() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let currentIDs = Set(displays.map { $0.displayID })
        let newIDSet = Set((0..<Int(displayCount)).map { displayIDs[$0] })

        // Clean up DDC cache for removed displays to prevent stale entries accumulating
        let removedIDs = currentIDs.subtracting(newIDSet)
        removedIDs.forEach {
            DDCService.shared.clearCache(for: $0)
            BrightnessService.shared.invalidateDDCState(for: $0)
        }

        // Diff-based refresh: keep existing DisplayInfo objects (preserves @Published state)
        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

        var updatedDisplays: [DisplayInfo] = []
        var addedDisplays: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if let existing = existingByID[id] {
                updatedDisplays.append(existing)
            } else {
                let info = DisplayInfo(displayID: id)
                updatedDisplays.append(info)
                addedDisplays.append(info)
            }
        }

        displays = updatedDisplays
        DisplayManagerAccessor.shared.displays = updatedDisplays

        // Regenerate built-in presets (HiDPI Mode / Native Mode) from updated display list.
        PresetService.shared.refreshBuiltins()

        // Only load details / refresh brightness for newly appeared displays
        for display in addedDisplays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
            Task {
                await display.loadDetails()
                // Auto-enable HiDPI for new external 2K+ displays that don't have it yet
                if !display.isBuiltin {
                    await self.autoEnableHiDPIIfNeeded(for: display)
                }
                PresetService.shared.refreshBuiltins()
            }
        }

        // Saved gamma / software brightness is restored for *all* displays by the
        // scheduled pass the reconfiguration callback triggers — the reset hits every
        // display, not only the one that appeared (see `scheduleDisplayStateRestore`).
        scheduleDisplayStateRestore()

        // For displays that were already present, only update bounds/main flag (no DDC probe).
        let keptIDs = currentIDs.intersection(newIDSet)
        for display in updatedDisplays where keptIDs.contains(display.displayID) {
            display.bounds = CGDisplayBounds(display.displayID)
            display.isMain = CGDisplayIsMain(display.displayID) != 0
        }
    }

    /// Auto-enables the HiDPI plist override for external 2K+ displays that don't have it yet.
    /// This ensures switching between different monitors "just works" without manual re-enable.
    ///
    /// Opt-in only (`fd.hidpi.autoEnable`, default off): enabling writes a persistent
    /// override into /Library/Displays with administrator privileges, so it must never
    /// happen without the user asking for it.
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) async {
        guard UserDefaults.standard.bool(forKey: Self.autoEnableHiDPIKey) else { return }

        // Virtual displays already control their own HiDPI mode; writing a plist
        // override for vendor 0xEEEE is useless and can trigger an admin prompt.
        guard !VirtualDisplayService.shared.isVirtualDisplay(display.displayID) else { return }

        // macOS already offers HiDPI modes for this display (every 4K+ panel does), so an
        // override adds nothing — and the mode re-enumeration it triggers can move the
        // display onto a resolution the user never picked. Nothing to enable.
        guard !display.availableModes.isEmpty else { return }
        guard !display.availableModes.contains(where: { $0.isHiDPI }) else { return }

        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }

        // Already enabled — nothing to do
        guard !HiDPIService.shared.isHiDPIEnabled(vendor: vendor, product: product) else { return }

        // Determine native resolution from available modes
        let (nativeW, nativeH) = display.nativeResolution

        // Only auto-enable for 2K+ displays (width >= 2560 or total pixels >= 2560*1440)
        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

        print("[DisplayManager] Auto-enabling HiDPI for \(display.name) (\(nativeW)×\(nativeH), vendor=\(vendor), product=\(product))")

        let err = await HiDPIService.shared.enableHiDPI(
            for: display.displayID,
            vendor: vendor,
            product: product,
            nativeWidth: nativeW,
            nativeHeight: nativeH
        )

        if let err {
            print("[DisplayManager] Auto-enable HiDPI failed: \(err)")
        } else {
            print("[DisplayManager] Auto-enable HiDPI succeeded, refreshing modes")
            HiDPIService.shared.refreshModes(for: display)
            // Give IOServiceRequestProbe time to re-enumerate modes
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await display.loadDetails()
            PresetService.shared.refreshBuiltins()
        }
    }

    /// Runs the optional "external displays above the built-in display" arrangement
    /// exactly once per launch. MenuBarExtra content is recreated whenever the panel
    /// opens, so this must never be called unguarded from a view `.task`.
    func scheduleInitialArrangeOnce() {
        guard !didScheduleInitialArrange else { return }
        didScheduleInitialArrange = true
        guard UserDefaults.standard.bool(forKey: "fd.arrangement.externalAbove") else { return }
        Task { @MainActor in
            // Give WindowServer time to finish enumerating displays after launch.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.arrangeExternalAboveBuiltin()
        }
    }

    /// Debounces calls to `arrangeExternalAboveBuiltin()` — coalesces bursts of config-change
    /// callbacks into a single rearrange that fires 500 ms after the last callback arrives.
    func scheduleAutoArrange() {
        guard UserDefaults.standard.bool(forKey: "fd.arrangement.externalAbove") else { return }
        autoArrangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.arrangeExternalAboveBuiltin()
        }
        autoArrangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func setupReconfigCallback() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        callbackContext = ctx
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, ctx)
    }

    /// Refreshes mode info and main-display flag for already-tracked displays
    /// (for setModeFlag / setMainFlag events).
    /// Cheaper than a full `refreshDisplays()` — does not add/remove DisplayInfo objects.
    func refreshExistingDisplayModes() {
        for display in displays {
            // Always refresh geometry synchronously — it is cheap and stale bounds
            // make the optional auto-arranger compute wrong targets.
            display.bounds = CGDisplayBounds(display.displayID)
            display.pixelWidth = CGDisplayPixelsWide(display.displayID)
            display.pixelHeight = CGDisplayPixelsHigh(display.displayID)
            display.isOnline = CGDisplayIsOnline(display.displayID) != 0
            display.isEnabled = CGDisplayIsActive(display.displayID) != 0
            // Always refresh isMain synchronously since it's cheap and needed for setMainFlag events.
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            Task {
                let newMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: display.displayID)
                }.value
                display.currentDisplayMode = newMode
            }
        }
    }

    /// Toggle a display on/off.
    /// NOTE: macOS has no public API for enabling/disabling individual displays
    /// (CGConfigureDisplayEnabled is private). This function always returns false
    /// to signal to callers that the operation is not supported.
    @discardableResult
    func toggleDisplay(_ display: DisplayInfo) -> Bool {
        // No-op: cannot enable/disable displays via public API
        return false
    }

    /// Makes the target display the main display by repositioning it to origin (0, 0).
    func setAsMainDisplay(_ display: DisplayInfo) {
        Task { @MainActor in
            let ok = await ArrangementService.shared.setAsMainDisplay(display.displayID)
            if ok { self.refreshDisplays() }
        }
    }

    /// Positions all external displays above the built-in display, packed left-to-right
    /// and centered as a group. Controlled by `fd.arrangement.externalAbove` (default off).
    /// Virtual displays are excluded: they are managed by VirtualDisplayService and must
    /// never be treated as physical monitors by the auto-arranger.
    /// Displays that are mirroring another display are excluded too: they have no origin
    /// of their own and are never repositioned (see `ArrangementService.apply`).
    func arrangeExternalAboveBuiltin() {
        guard UserDefaults.standard.bool(forKey: "fd.arrangement.externalAbove") else { return }
        guard let builtin = displays.first(where: { $0.isBuiltin }) else { return }

        let externals = displays.filter {
            !$0.isBuiltin &&
            $0.isOnline &&
            !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) &&
            CGDisplayMirrorsDisplay($0.displayID) == kCGNullDirectDisplay
        }
        guard !externals.isEmpty else { return }

        let builtinBounds = CGDisplayBounds(builtin.displayID)
        let builtinX = Int(builtinBounds.origin.x)
        let builtinY = Int(builtinBounds.origin.y)
        let builtinWidth = Int(builtinBounds.width)

        let totalWidth = externals.reduce(0) {
            $0 + Int(CGDisplayBounds($1.displayID).width)
        }
        var cursorX = builtinX + (builtinWidth - totalWidth) / 2

        var arrangeItems: [(id: CGDirectDisplayID, x: Int32, y: Int32)] = []
        for ext in externals {
            let bounds = CGDisplayBounds(ext.displayID)
            arrangeItems.append((
                id: ext.displayID,
                x: Int32(cursorX),
                y: Int32(builtinY - Int(bounds.height))
            ))
            cursorX += Int(bounds.width)
        }

        // Idempotence: do not write a configuration that is already in effect.
        let needsMove = arrangeItems.contains { item in
            let bounds = CGDisplayBounds(item.id)
            return abs(Int(bounds.origin.x) - Int(item.x)) > 1 ||
                   abs(Int(bounds.origin.y) - Int(item.y)) > 1
        }
        guard needsMove else { return }

        Task { @MainActor in
            _ = await ArrangementService.shared.apply(origins: arrangeItems)
            self.refreshDisplays()
        }
    }
}
