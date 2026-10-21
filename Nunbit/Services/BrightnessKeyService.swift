import AppKit
import CoreGraphics

// MARK: - C Event Tap Callback

/// Modifier combinations macOS owns itself: ⌥-brightness opens Displays settings and
/// ⇧⌥-brightness is a quarter step. Fn / caps-lock are deliberately not included — the
/// brightness keys themselves can arrive with `maskSecondaryFn` set.
/// File-scope so the nonisolated callback can read it without touching main-actor state.
private let reservedBrightnessKeyModifiers: CGEventFlags =
    [.maskShift, .maskControl, .maskAlternate, .maskCommand]

/// Global C callback for the CGEventTap. `userInfo` carries an Unmanaged<BrightnessKeyService>.
/// The tap is registered on the main run loop, so this callback always fires on the main thread.
private func brightnessKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<BrightnessKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEventFromCallback(type: type, event: event)
}

// MARK: - BrightnessKeyService

/// Intercepts macOS brightness keys and routes them to the display under the mouse cursor.
/// When the cursor is on an external display the key event is consumed and the external
/// display's brightness is adjusted via BrightnessService. When the cursor is on the
/// built-in display the event is passed through so macOS adjusts it normally.
@MainActor
final class BrightnessKeyService: @unchecked Sendable {
    static let shared = BrightnessKeyService()
    private init() {}

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Retained Unmanaged reference passed into the C callback. Released in stop().
    private var selfRetained: Unmanaged<BrightnessKeyService>?
    /// Number of poll retries attempted.
    private var pollRetryCount = 0
    /// Max poll retries before giving up (2s × 15 = 30s).
    private static let maxPollRetries = 15
    /// Set by stop(). Once true, no pending accessibility retry may install the tap again.
    private var isStopped = false

    // MARK: - NX Media Key Constants
    // Marked nonisolated(unsafe) so they can be read from the nonisolated callback method.
    // These are immutable compile-time constants so there is no data-race risk.

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private nonisolated(unsafe) static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS — the subtype value for media/function keys.
    private nonisolated(unsafe) static let nxSubtypeAuxControlButtons: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP
    private nonisolated(unsafe) static let nxKeytypeBrightnessUp: Int = 2
    /// NX_KEYTYPE_BRIGHTNESS_DOWN
    private nonisolated(unsafe) static let nxKeytypeBrightnessDown: Int = 3

    /// Each key press moves brightness by 1/16 (≈ 6.25 %), matching macOS native behaviour.
    private nonisolated(unsafe) static let brightnessStep: Double = 100.0 / 16.0

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility permissions.
    /// Safe to call multiple times — a running tap will not be re-created.
    func start() {
        isStopped = false
        installTap()
    }

    /// Removes the event tap and releases the retained self reference.
    /// Final: a pending accessibility retry can no longer re-install the tap afterwards.
    func stop() {
        isStopped = true

        pollTimer?.invalidate()
        pollTimer = nil
        pollRetryCount = 0

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        selfRetained?.release()
        selfRetained = nil

        print("[BrightnessKeyService] Event tap removed.")
    }

    /// Creates and registers the tap. Called by `start()` and by the accessibility poll,
    /// which is why the `isStopped` guard lives here rather than in `start()`.
    private func installTap() {
        guard !isStopped, eventTap == nil else { return }

        // Try creating the tap directly — AXIsProcessTrusted can be unreliable
        // with ad-hoc signed Debug builds (TCC entry invalidates after each rebuild).
        let retained = Unmanaged.passRetained(self)
        selfRetained = retained

        let systemDefinedMask = CGEventMask(1 << Self.cgEventTypeSystemDefinedRaw)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: brightnessKeyEventCallback,
            userInfo: retained.toOpaque()
        )

        guard let tap else {
            retained.release()
            selfRetained = nil
            NSLog("[BrightnessKeyService] Event tap creation failed — no accessibility permission")
            pollForAccessibility()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        // A successful install resets the retry budget, so a later failure polls afresh.
        self.pollRetryCount = 0

        NSLog("[BrightnessKeyService] Event tap installed successfully")
    }

    // MARK: - Accessibility Polling

    private var pollTimer: Timer?

    /// Polls every 2 seconds by attempting to create the tap. Stops after maxPollRetries.
    private func pollForAccessibility() {
        pollTimer?.invalidate()
        // Add to the main run loop explicitly (.default mode, like the previous
        // scheduledTimer). The block is nonisolated as far as the compiler knows, but a
        // timer on the main run loop always fires on the main thread, where the main actor
        // is the current executor — the same mechanism as the event-tap callback.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
    }

    /// One retry tick. Main-actor isolated: only ever called from the main run loop timer.
    private func pollTick() {
        pollRetryCount += 1
        if pollRetryCount > Self.maxPollRetries {
            NSLog("[BrightnessKeyService] Gave up after %d retries — grant Accessibility permission and restart app", Self.maxPollRetries)
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        NSLog("[BrightnessKeyService] Poll %d/%d: retrying…", pollRetryCount, Self.maxPollRetries)
        pollTimer?.invalidate()
        pollTimer = nil
        // installTap() refuses once stop() has run, so a pending retry cannot
        // resurrect the tap after shutdown.
        installTap()
    }

    // MARK: - Event Handling
    // Called from the C callback which runs on the main run loop thread.
    // We use nonisolated so Swift 6 doesn't complain about CGEvent (non-Sendable) crossing
    // actor boundaries; all actual state access is done synchronously on the main thread.

    /// Returns `nil` to consume the event, or the event itself to pass it through.
    /// Separated from the callback to keep the C-bridging function minimal.
    ///
    /// The event is consumed only when this call is actually going to adjust something.
    nonisolated func handleEventFromCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it (e.g. after a timeout).
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
           type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            DispatchQueue.main.async {
                if let tap = self.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.cgEventTypeSystemDefinedRaw else {
            return Unmanaged.passUnretained(event)
        }

        // Convert to NSEvent to inspect media-key subtype.
        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        guard nsEvent.subtype.rawValue == Self.nxSubtypeAuxControlButtons else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 >> 16) & 0xFF
        let isKeyDown = (data1 & 0x0100) == 0   // bit 8 clear → key down

        // Only intercept brightness keys.
        guard keyCode == Self.nxKeytypeBrightnessUp || keyCode == Self.nxKeytypeBrightnessDown else {
            return Unmanaged.passUnretained(event)
        }

        // For key-up events always pass through — only consume key-down on external displays.
        guard isKeyDown else { return Unmanaged.passUnretained(event) }

        // Modifier combinations belong to macOS: ⌥-brightness opens Displays settings and
        // ⇧⌥-brightness takes a quarter step. Passing them through keeps that behaviour.
        guard event.flags.intersection(reservedBrightnessKeyModifiers).isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        // Determine which display is under the cursor.
        // NSEvent.mouseLocation and NSScreen.screens are main-thread APIs, and this callback
        // runs on the main run loop (the tap's CFMachPort source is added to CFRunLoopGetMain()).
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return Unmanaged.passUnretained(event)
        }

        if CGDisplayIsBuiltin(displayID) != 0 {
            // Cursor on built-in display — let macOS handle it normally.
            return Unmanaged.passUnretained(event)
        }

        let step = (keyCode == Self.nxKeytypeBrightnessUp) ? Self.brightnessStep : -Self.brightnessStep

        // Decide synchronously whether this press will really adjust something, because a
        // consumed event that changes nothing swallows the key press entirely. The decision
        // needs DisplayManager / VirtualDisplayService state, which is main-actor isolated:
        // this callback is a CFRunLoopSource callback on CFRunLoopGetMain() (the tap's
        // CFMachPort source), so the main actor is the current executor here.
        let willAdjust: Bool = MainActor.assumeIsolated {
            // Virtual displays are not brightness-controllable and are excluded everywhere
            // else in the app; never let the keys drive one.
            guard !VirtualDisplayService.shared.isVirtualDisplay(displayID) else { return false }
            // No DisplayInfo → nothing to adjust; pass the key through to macOS instead of
            // consuming it and doing nothing.
            return DisplayManagerAccessor.shared.displays.contains { $0.displayID == displayID }
        }

        guard willAdjust else { return Unmanaged.passUnretained(event) }

        // Adjust off the callback: the DDC write and the OSD XPC call must not run inside the tap.
        Task { @MainActor in
            guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
            else { return }
            let newBrightness = max(0.0, min(100.0, display.brightness + step))
            // Use smooth animation — cancels any in-progress animation automatically.
            BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)

            // Show OSD on the external display where brightness was adjusted.
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) {
                BrightnessHUDService.shared.show(brightness: newBrightness, on: screen)
            }
        }

        // Return nil to consume (suppress) the event so macOS doesn't also adjust brightness.
        return nil
    }
}
