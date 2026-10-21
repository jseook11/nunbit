# Phase 18: Stability Hardening

> Status: Completed | Estimate: Medium complexity

## Goal

Extend the timeout protection pattern for blocking CG calls to the entire project, ensure HiDPI state is automatically restored after sleep/wake, and re-apply the arrangement automatically after a display configuration change.

## Tasks

### Task 1: Unify timeout protection for blocking CG calls
- [x] Extract `runWithTimeout` from VirtualDisplayService into a shared utility function (place it in `Utilities/` or `Services/CGHelpers.swift`)
- [x] MirrorService: wrap the `CGCompleteDisplayConfiguration` calls in `enableMirror`/`disableMirror` with `runWithTimeout`
- [x] ArrangementService: wrap the `CGCompleteDisplayConfiguration` call in `setPosition` with `runWithTimeout`
- [x] ResolutionService: add a 10-second timeout to `applyModeSync` (currently waits on `CGCompleteDisplayConfiguration` indefinitely)

**Implementation hints**: `runWithTimeout` is already proven inside VirtualDisplayService — reuse the same pattern directly. Mind the `@Sendable` constraints.

### Task 2: Automatic re-arrangement on display configuration change
- [x] Register `CGDisplayRegisterReconfigurationCallback` in AppDelegate or DisplayManager
- [x] In the callback, detect that the configuration change has finished (`flags` contains `beginConfigurationFlag`, then wait for a callback that does not)
- [x] After the configuration change completes, wait 500ms and call `displayManager.arrangeExternalAboveBuiltin()`
- [x] Avoid duplicate triggers: use a debounce mechanism so multiple callbacks within 500ms only run the last one

**Implementation hints**: Pass `Unmanaged.passRetained(self)` as the context parameter of `CGDisplayRegisterReconfigurationCallback` to prevent dangling pointers — this is an established project rule. The callback runs on a system thread, so use `DispatchQueue.main.async` to hop back to the main thread.

### Task 3: Automatically restore HiDPI after sleep/wake
- [x] In the `didWakeNotification` handler of AppDelegate, check whether `VirtualDisplayService.hiDPIActiveDisplayIDs` has any active sessions
- [x] If it does, check whether the virtual display is still online (`CGDisplayIsOnline`); if it was lost, recreate it + mirror + apply the resolution
- [x] Restore sequence: create → apply settings → sleep 500ms → mirror → sleep 500ms → setDisplayMode → arrangeExternalAboveBuiltin
- [x] Persist the HiDPI state to UserDefaults (`fd.hiDPI.activePhysicalIDs`) so it can be restored after an app restart

**Implementation hints**: WindowServer needs time to settle after wake, so add a 2-second initial delay to the whole restore sequence. Refer to the existing `enableHiDPIVirtual` flow in VirtualDisplayService.

### Task 4: Error recovery and user feedback
- [x] Show a menu bar status hint when a CG call times out (no modal dialog; use the `statusMessage` pattern)
- [x] When HiDPI restoration fails, prompt the user to turn it back on manually
- [x] After 3 consecutive failures, disable HiDPI automatically and notify the user

**Implementation hints**: Reuse the existing `statusMessage` pattern from HiDPIVirtualRowView.

## Acceptance Criteria

```bash
# Build passes
xcodebuild -scheme Nunbit -configuration Debug build 2>&1 | tail -3

# Manual tests
# 1. Enable HiDPI → close lid to sleep → wake → HiDPI restores automatically + arrangement is correct
# 2. Enable HiDPI → unplug external display → replug → no crash
# 3. Switch resolution → arrangement stays directly above
```
