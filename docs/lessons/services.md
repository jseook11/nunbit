# Lessons Learned — Cross-Service Collaboration / Concurrency / Resource Management

> Updated: 2026-03-05

## Feature Interaction / Cross-Service Collaboration (Round 3-4 Optimization)

### L-008: Two services writing the same CoreGraphics resource overwrite each other
- **Symptom**: After setting a gamma adjustment, dragging the brightness slider makes the gamma effect disappear (or vice versa)
- **Cause**: Both GammaService and BrightnessService call CGSetDisplayTransfer*, and the later call completely overwrites the former
- **Fix**: Designate GammaService as the sole writer; BrightnessService stores the brightness factor in softwareBrightnessFactors, and GammaService reads it in applyFormula and multiplies it into rHi/gHi/bHi
- **Lesson**: When two services share an underlying resource, you must designate a single owner, and other parties must influence it through an interface rather than writing directly
- **Date**: 2026-03-04

### L-009: macOS sleep/wake resets all CGSetDisplayTransfer* effects
- **Symptom**: Gamma adjustments and software brightness are all lost after the Mac sleeps
- **Cause**: On sleep, macOS resets the display transfer function to the system default, so CGSetDisplayTransfer* effects are not persistent
- **Fix**: Register for NSWorkspace.didWakeNotification, and re-apply to all displays 500ms after wake
- **Lesson**: Any feature that writes display hardware state must account for reset after sleep/wake, and testing must cover this scenario
- **Date**: 2026-03-04

### L-010: CGDisplayRegisterReconfigurationCallback must use passRetained
- **Symptom**: Theoretical crash risk: the C callback accesses a dangling pointer
- **Cause**: passUnretained does not increase the reference count, so if self is deallocated the callback accesses a dangling pointer
- **Fix**: passRetained + paired release (in stopMonitoring/deinit)
- **Lesson**: Always use passRetained for a self pointer passed to a C callback; this has already occurred twice in the project (DisplayManager + ConfigProtectionService)
- **Date**: 2026-03-04

### L-011: AutoBrightness and manual adjustment must have a cooldown mechanism
- **Symptom**: A manual brightness adjustment is overridden by AutoBrightness 2 seconds later
- **Cause**: applyBrightness only checks the difference and has no protection for "the user recently adjusted manually"
- **Fix**: Add an isAutoAdjust parameter to setBrightness; record lastManualAdjustDate on manual calls, and have AutoBrightness check a 30s cooldown
- **Lesson**: Automatic adjustment features must have a pause mechanism after manual intervention
- **Date**: 2026-03-04

## Concurrency / Resource Management (Round 5 Optimization)

### L-012: GammaService's activeAdjustments dictionary must be locked
- **Symptom**: Data race risk — BrightnessService reads hasActiveAdjustment from a background queue while GammaService writes activeAdjustments from the MainActor
- **Cause**: The dictionary has no synchronization protection; concurrent reads and writes from multiple threads are undefined behavior in Swift (may crash or corrupt data)
- **Fix**: Add an NSLock and lock all activeAdjustments reads and writes (hasActiveAdjustment/apply/reapply/reset, etc.)
- **Lesson**: Any mutable state accessed by multiple actors must be locked, whether or not a race has currently been triggered
- **Date**: 2026-03-04

### L-013: GammaService's quantized path must apply the brightness factor too
- **Symptom**: Software brightness silently stops working in quantized mode (quantizationLevels < 256)
- **Cause**: applyFormula reads the softwareBrightness factor, but applyQuantizedTable does not; the two paths are inconsistent
- **Fix**: applyQuantizedTable must also read brightnessFactor and scale rHi/gHi/bHi
- **Lesson**: When a single service has multiple execution paths, all paths must apply the same modification logic
- **Date**: 2026-03-04

### L-014: On sleep/wake, BrightnessService must reapply before GammaService
- **Symptom**: On screen wake there is a brief white flash (full brightness) before it recovers
- **Cause**: When GammaService.reapply was called first, softwareBrightnessFactors had not yet been restored, so applyFormula read 1.0 and wrote that to the hardware
- **Fix**: On wake, call BrightnessService.reapply first, then GammaService.reapply (ensuring the factor is ready)
- **Lesson**: Reapply operations with dependencies must be called in dependency order; BrightnessService is the data provider for GammaService
- **Date**: 2026-03-04

### L-015: Closing an NSWindow must stop the associated SCStream
- **Symptom**: When the user clicks the red close button of the PiP/Stream window, the stream keeps running in the background and consumes resources
- **Cause**: NSWindowController did not implement NSWindowDelegate.windowWillClose, so the close event did not trigger stopCapture
- **Fix**: Have PiPWindowController/StreamWindowController implement windowWillClose → viewModel.stopCapture(), and also set window.delegate = self
- **Lesson**: Both system-provided close entry points (the red button) and in-app close buttons must clean up resources; handling only one of them is not enough
- **Date**: 2026-03-04

### L-016: Never call removeValue while iterating a Dictionary
- **Symptom**: NotchOverlayManager.screenParametersChanged() called removeValue while iterating overlayWindows, a potential crash
- **Cause**: Swift Dictionary does not support mutating itself during a for-in iteration; the behavior is undefined
- **Fix**: Collect the keys to delete in a temporary array and remove them all after the loop
- **Lesson**: When doing a for-in iteration over any collection, you must not add or remove elements from that collection (the same class of problem as ConcurrentModificationException in other languages)
- **Date**: 2026-03-04

### L-017: UserDefaults keys must have an app namespace prefix
- **Symptom**: SettingsService/AutoBrightnessService/ConfigProtectionService used bare keys (such as "launchAtLogin")
- **Cause**: A bare key may collide with macOS system defaults or a future third-party library, causing an unexpected value to be read or a system setting to be overwritten
- **Fix**: Add a `fd.` prefix uniformly (fd.launchAtLogin, fd.AutoBrightnessEnabled, etc.)
- **Lesson**: UserDefaults key naming convention: `<app_prefix>.<key>`
- **Date**: 2026-03-04

### L-018: Mirror source/target API query direction
- **Symptom**: refreshMirrorState queries with CGDisplayMirrorsDisplay(source) and always returns nil (source does not clone anyone)
- **Cause**: CGDisplayMirrorsDisplay(X) returns "the target that X clones", but SOURCE itself is not the cloner
- **Fix**: Query in reverse — iterate all displays and find the one where CGDisplayMirrorsDisplay(candidate) == source (i.e. the target)
- **Lesson**: Mirror API semantics: SOURCE is the one being cloned, and TARGET is the cloner; the query should be made from the TARGET's perspective ("who is cloning me")
- **Date**: 2026-03-04

### L-019: IOPMAssertion must be released before creating a new assertion
- **Symptom**: Every time the prevent-sleep toggle in ManageDisplayView is turned on, one IOPMAssertion leaks; the old ID is overwritten and can no longer be released
- **Cause**: createSleepAssertion() did not check sleepAssertionID != 0 and simply overwrote it
- **Fix**: Release the old assertion before creating a new one; in onDisappear only release when !preventSleep (so it stays in effect while the toggle is ON)
- **Lesson**: System resources (IOPMAssertion, IO iterators, etc.) must strictly pair create/release; release the old one before overwriting an ID
- **Date**: 2026-03-04

### L-032: Never call a main-actor closure from a background queue
- **Symptom**: Dragging the brightness slider for an external display in the menu bar instantly kills the app (the whole process exits, not just the panel)
- **Cause**: `BrightnessService.setBrightness` is `@MainActor`, so its non-`@Sendable` completion handed to `DDCService.writeAsync` inherited main-actor isolation — but `writeAsync` invoked it on `com.jseook11.ddc`. Swift 6's runtime isolation check called `dispatch_assert_queue`, which fails with SIGTRAP (EXC_BREAKPOINT). The same latent crash existed in `setBrightnessSmooth` (write completion) and `refreshBrightness` (`readAsync` completion).
- **Fix**: Declare the DDC completion parameters `@MainActor` and deliver them with `Task { @MainActor in completion(...) }` from `ddcQueue`, never by calling them directly on that queue.
- **Lesson**: A non-`@Sendable` closure parameter inherits the isolation of the enclosing context. If the callee runs it on another queue, Swift 6 traps at runtime even though the code compiles. Either mark the parameter `@Sendable` (and keep the body nonisolated) or mark it `@MainActor` and hop explicitly.
- **Date**: 2026-10-21
