# Blocking Issues — Nunbit

> Updated: 2026-10-21 | **Must read before starting work; unresolved P0/P1 issues must be handled first**

## Scheduling Rules

1. Finish reading this file → if there are P0/P1 issues → **resolve them one by one from highest to lowest priority, and only work on the ROADMAP once all are cleared**
2. If there are only P2 issues → you may work on ROADMAP tasks first, interleaving P2 fixes
3. After resolving → move it to the "Resolved" section below, writing down the fix
4. Ran into a new blocker during work → add it here immediately

---

## 🔴 P0 — Hard Blockers

(None for now)

---

## 🟡 P1 — High Priority

### B-005: The documented build command fails on this machine (signing team mismatch)
- **Symptom**: `xcodebuild -scheme Nunbit -configuration Debug build` fails with `No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "29W56PHWJR" with a private key was found`. Note that `| tail -5` hides this — the pipeline's exit code is tail's, so a broken build looks like a success.
- **Cause**: `project.yml` pins `DEVELOPMENT_TEAM: 29W56PHWJR`, but the local identity is `Apple Development: basut@pm.me (YCS9G8TFJ8)` with OU `GBB276UY2D`.
- **Workaround**: add `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO` (already documented in `docs/PERSONAL-FORK.md`).
- **Proper fix**: make the team configurable for forks (e.g. drop the pinned `DEVELOPMENT_TEAM` from `project.yml` and set it via an xcconfig that is git-ignored, or document the override in CLAUDE.md's Verification Chain so nobody is misled by a green-looking `tail -5`).
- **Added on**: 2026-10-21

---

## 🔵 P2 — Normal Priority

### B-007: The Intel DDC read path parses replies with no validation at all
- **File**: `Nunbit/Services/DDCService.swift:615-618` (`intelReadSynchronous`)
- **Symptom**: `maxVal`/`curVal` are read straight out of `rb[6..9]` with no check on the source address, payload length, opcode, result code, echoed VCP or checksum. This is the same class of bug as the one just fixed on the ARM64 path (commit 8f51901) — a monitor that answers with garbage yields a nonsense `max`, and every later write is scaled against it.
- **Fix**: apply the same guard the ARM64 path now uses. Best: extract one `parseVCPReply(_ bytes: [UInt8], expectedVCP: UInt8) -> (current: UInt16, max: UInt16)?` helper and call it from both paths so the two can never drift again.
- **Added on**: 2026-10-21

### B-008: DDC reply validation still misses the checksum and `current <= max`
- **File**: `Nunbit/Services/DDCService.swift` (`arm64Read`, the guard added in 8f51901)
- **Symptom**: The new guard checks source address, length, opcode, result code and echoed VCP — which is enough to reject the observed garbage (`6e 80 be d0 …`, rejected because `0x80 & 0x7F == 0x00 != 0x08`) — but it does not verify the DDC/CI checksum (XOR of 0x6E with the payload) and does not reject `cur > max`. A partially corrupt reply can still slip through with a plausible-looking but wrong `max`.
- **Fix**: validate the checksum and add `guard curVal <= maxVal, maxVal > 0`.
- **Added on**: 2026-10-21

### B-009: `IOAVServiceRef` is never released (CF object leak)
- **File**: `Nunbit/Services/DDCService.swift:295-299` (`invalidateAVServiceCache`)
- **Symptom**: The function only does `avServiceCache.removeValue(forKey:)`; the `IOAVServiceRef` stored there is never `CFRelease`d. Every display reconnect leaks one AV service object, and the cache invalidation path (also called from the reconfiguration handling at `:633`) leaks each time.
- **Fix**: `CFRelease` the removed value (the cache must own the only strong reference — check the insert site to confirm ownership before adding the release).
- **Added on**: 2026-10-21

### B-010: Auto-brightness sensitivity is clobbered on every launch
- **File**: `Nunbit/Services/AutoBrightnessService.swift:149-159` (`loadPrefs`/`savePrefs`)
- **Symptom**: `loadPrefs()` assigns `isEnabled` first. Its `didSet` fires immediately and calls `savePrefs()`, which writes the not-yet-loaded `sensitivity` (still its default `1.0`) back to disk — and only then does `loadPrefs()` read the stored sensitivity into memory. The user's stored sensitivity is therefore overwritten with 1.0 on every launch. (Verified by compiling a minimal reproduction: property observers do fire for assignments made inside a method called from `init`.)
- **Fix**: read both values into locals and assign them with the observers suppressed, or set a `isLoading` flag that `savePrefs()` checks.
- **Added on**: 2026-10-21

### B-011: Auto-brightness IOKit fallback can read the wrong display
- **File**: `Nunbit/Services/AutoBrightnessService.swift:83-91`
- **Symptom**: When the private `CoreDisplay_Display_GetUserBrightness` symbol is unavailable, the fallback enumerates every `IODisplayConnect` service and returns the first one reporting `kIODisplayBrightnessKey > 0` — with no check that the service belongs to the built-in display. On a machine with an external monitor that exposes that key, the "builtin brightness" driving the sync is actually the external display's, so the sync feeds back on itself.
- **Fix**: match the service to the built-in display (vendor/product ID of `builtinID`, or restrict the search to the internal panel) before reading, or drop the fallback entirely and report "no builtin display found".
- **Added on**: 2026-10-21

### B-012: Auto-brightness syncs to virtual displays
- **File**: `Nunbit/Services/AutoBrightnessService.swift` (`applyBrightness`, the loop over `DisplayManagerAccessor.shared.displays`)
- **Symptom**: The only filter is `guard !display.isBuiltin`; `DisplayInfo` has no virtual-display flag, so the sync also drives the headless/virtual display. Everywhere else virtual displays are deliberately excluded (`DisplayManager.swift:135,256`, `MenuBarView.swift:145-147`, `PresetService`).
- **Fix**: add an `isVirtual` property to `DisplayInfo` (set from the known virtual display IDs) and use it for exclusion consistently in auto-brightness, DDC, brightness keys and presets.
- **Added on**: 2026-10-21

### B-013: A user dragging a display in System Settings leaves the app's arrangement UI stale
- **File**: `Nunbit/Services/DisplayManager.swift:14`
- **Symptom**: The reconfiguration callback filters on `[.addFlag, .removeFlag, .setMainFlag, .setModeFlag]` and returns early for anything else. A pure move sets `.movedFlag`, which is not in that set, so `refreshDisplays`/`refreshExistingDisplayModes` never run and the cached `DisplayInfo.frame` origins keep the old positions until some unrelated change triggers a refresh. The arrangement UI then shows and can re-apply stale coordinates.
- **Fix**: include `.movedFlag` in the refresh path (refresh only, do not auto-arrange on a move — that would fight the user's drag).
- **Added on**: 2026-10-21

### B-014: `HiDPIService.refreshModes` shares one task across all displays
- **File**: `Nunbit/Services/HiDPIService.swift:59-73`
- **Symptom**: `refreshTask` is a single stored task that the method cancels before starting a new one, but the task captures the display it was created for. Refreshing display B while display A's refresh is still sleeping (500 ms) cancels A's, so A's `availableModes`/`currentDisplayMode` are never updated. Reachable from `DisplayManager.swift:164` (per newly added display), `HiDPIView.swift:95` and `DisplayModeListView.swift:56`.
- **Fix**: key the tasks by display ID (`[CGDirectDisplayID: Task<Void, Never>]`) so each display's refresh is independent.
- **Added on**: 2026-10-21

### B-015: Preset failures are invisible to the user
- **File**: `Nunbit/Services/PresetService.swift:52-152` (`applyPreset`)
- **Symptom**: Every failure is only `print`ed under `#if DEBUG`: no matching mode (`:126-127`), no display matched the UUID (`:81`), display offline (`:85`), and the return values of `setDisplayMode` (`:122`) and `setPosition` (`:147`) are logged but never surfaced. Applying a preset on a different display setup appears to do nothing at all.
- **Fix**: return a per-display result summary and show it in the preset UI (follow the error-banner pattern used in `ColorProfileView`).
- **Added on**: 2026-10-21

### B-016: `isNewerVersion` mis-parses pre-release tags
- **File**: `Nunbit/Services/UpdateService.swift:76-88`
- **Symptom**: `split(separator: ".").compactMap { Int($0) }` silently drops any component that is not a pure integer. For `1.2.0-beta` the last component becomes `nil` and is dropped, so the remote version is compared as `1.2`. The `v` prefix is already stripped at `:62`, so ordinary release tags are fine — this only mis-handles pre-release suffixes, which can produce a missed update. Low impact, cheap to fix.
- **Fix**: parse with a proper version comparison (or strip the pre-release suffix explicitly and compare the numeric core).
- **Added on**: 2026-10-21

---

## ✅ Resolved

### ~~B-006: The FreeDisplay → Nunbit rename orphaned all of the user's persisted settings~~
- **Cause**: The rename changed the bundle identifier, so everything the user had configured stayed in the `com.freedisplay.app` domain while the app now reads `com.jseook11.nunbit` (and `~/Library/Application Support/FreeDisplay/` instead of `Nunbit/`).
- **Fix**: `SettingsService.migrateLegacyFreeDisplaySettingsIfNeeded` runs once at launch (marker `fd.migratedFromFreeDisplay`), **additively** — a key is copied only when the new domain does not have it, and files in the old Application Support folder are copied only when the destination is absent. A wholesale copy would be actively harmful: by the time the migration ran, the new domain already held every meaningful key with a *newer* value the user had set since the rename (brightness 5 against the old 15, a re-created virtual-display config, a new headless config ID), so overwriting would have resurrected stale settings.
- **Outcome on the machine this was found on**: nothing needed to move — the only keys copied were `fd.brightness_3` (a legacy numeric key that `PerDisplayStore` ignores because the UUID-keyed value exists) and one `fd.expanded.*` UI-state key. The one genuinely lost item was the pre-rename `1920×1080` virtual-display config, superseded by the `2560×1440` one created after the rename.
- **Resolved on**: 2026-10-21
- **Lesson**: A rename/rebrand migration must be additive and must never assume the new domain is empty — by the time anyone writes the migration, the app has usually been running under the new name for a while and the user has already re-set what they care about.

### ~~B-030: Activating a virtual display silently wiped every display's brightness/gamma state~~
- **Symptom**: With brightness set low (DDC 5%) and a colour adjustment saved, turning a virtual display on made the physical monitor visibly brighter. It stayed that way until the user opened that display's *Image Adjustment* section, which restored it. Turning the virtual display off did the same.
- **Cause**: WindowServer discards the transfer table of **every** display whenever the display configuration changes — measured on macOS 26: a display at `lo=0.04 / hi=0.96` returns to `lo=0 / hi=1` the moment a `CGVirtualDisplay` is created, and again when it is destroyed. It is not limited to the display that changed. `DisplayManager.refreshDisplays()` only re-applied saved state for `addedDisplays`, so the displays that *stayed* connected were left at identity with nothing to restore them. `ImageAdjustmentView.onAppear` re-applies the saved adjustment, which is why opening that panel appeared to "fix" it.
- **Fix**: `DisplayManager.scheduleDisplayStateRestore()` re-applies software brightness and the gamma adjustment for every online display after any configuration change. It runs two passes (0.15 s and 1.2 s) because a write that lands while WindowServer is still committing the transaction is silently discarded; both the CoreGraphics reconfiguration callback and `NSApplication.didChangeScreenParametersNotification` trigger it. `GammaService.restoreAfterReconfiguration` prefers the live adjustment over the persisted one so an unsaved, in-flight adjustment survives.
- **Resolved on**: 2026-10-21
- **Lesson**: A silent, OS-initiated reset of shared hardware state needs an explicit re-assert pass keyed to the event that causes it — "restore it when a view appears" is not a recovery strategy, it just hides the bug until a user notices.

### ~~B-031: The HiDPI row reported a plist file, not the display's HiDPI state~~
- **Symptom**: A display already running a HiDPI resolution (MSI MD271UL, 4K, "looks like 2560×1440" with a 5120×2880 backing) showed **HiDPI Mode** as disabled. Enabling it wrote a plist override whose mode re-enumeration could move the display onto a resolution the user does not use.
- **Cause**: The row's state was `overrideState != .none`, i.e. "did Nunbit write a plist override". macOS provides HiDPI modes natively for every 4K+ panel, so the user's HiDPI had nothing to do with that file, and the file the app had written earlier was inert until the next reconnect. `generateScaledModes` also asks for `native × 2` backing (7680×4320 on a 4K panel), which is what a re-enumeration would land on.
- **Fix**: The row now reports the mechanism actually in effect. When macOS offers HiDPI modes for the display, the state is "is the current mode HiDPI" and the toggle switches between the HiDPI and non-HiDPI mode of the **same logical resolution** — no plist, no administrator prompt, no resolution change. The plist override remains only for displays with no HiDPI mode at all. A Nunbit-written override that a display no longer needs is reported in the subtitle and can be removed from the row's context menu. `autoEnableHiDPIIfNeeded` now also skips displays that already have HiDPI modes.
- **Resolved on**: 2026-10-21
- **Lesson**: A toggle must report the state of the thing the user cares about (the display's scaling), not the state of the mechanism this app happens to use to influence it.

### ~~B-029: A timed-out display-configuration transaction was abandoned, so the retry ran a second transaction concurrently~~
- **Cause**: `CGHelpers.runWithTimeout` dispatched each operation onto the global concurrent queue. When the deadline fired it resumed the caller with `fallback` while the Begin→Configure→Complete transaction kept running; `DisplayModeListView` then retried immediately, putting two transactions in flight.
- **Fix**: All `runWithTimeout` operations now run on one private serial queue. The timeout still returns `fallback` so no caller blocks, but a timed-out operation keeps holding the queue, and `outstandingTransactions`/`isTransactionInFlight` (incremented at submission, not at start) lets callers refuse to retry. `DisplayModeListView` checks it after its 200 ms backoff.
- **Resolved on**: 2026-10-21
- **Lesson**: A timeout must bound the *caller*, not the operation. If the operation cannot be cancelled, serialise it and make "still in flight" observable.

### ~~B-028: A mode switch showed the requested mode as current even when a different one was applied~~
- **Cause**: After the switch, when the refreshed mode did not match the request, `DisplayModeListView` assigned the requested mode to `currentDisplayMode`, so a HiDPI request silently satisfied by a non-HiDPI mode displayed as "Current" with the HiDPI badge. `availableModes` was also never refreshed.
- **Fix**: Re-read the real mode after the switch and assign that (including `nil` = explicitly unknown), never the request; refresh the mode list; if the applied mode differs from the request, show what was actually applied for 3 s.
- **Resolved on**: 2026-10-21
- **Lesson**: UI "current state" must come from the system, never from the last request.

### ~~B-027: Launch at Login reported success when registration had failed~~
- **Cause**: `LaunchService.toggle()` discarded the result of `enable()`/`disable()` and returned the requested state; the SettingsView binding then persisted it. Registration failures (app not in /Applications, `.requiresApproval`) showed ON while nothing was registered.
- **Fix**: New `LaunchService.setEnabled(_:) -> String?` re-verifies `SMAppService.mainApp.status` after the call, handles `.requiresApproval` explicitly, and returns a user-facing message. The switch now snaps back to the real state and shows an inline error banner.
- **Resolved on**: 2026-10-21
- **Lesson**: Never persist the value the user asked for; persist what the system actually reports.

### ~~B-026: Brightness keys hijacked modifier combinations and swallowed no-op presses~~
- **Cause**: `BrightnessKeyService` inspected no modifiers, so ⌥-brightness (Displays settings) and ⇧⌥-brightness (quarter steps) were consumed. The display lookup resolved asynchronously after the decision to consume, so an unmatched display produced a dead key press. Only built-in displays were excluded, so virtual displays could be driven.
- **Fix**: Any of ⌥ ⌘ ⌃ ⇧ passes through before the display lookup (Fn is intentionally not included — brightness keys can arrive with `maskSecondaryFn`). The consume decision is now synchronous via `MainActor.assumeIsolated` (safe: the tap source is added to `CFRunLoopGetMain()`), so the event is consumed only when an adjustment will really happen. Virtual displays are excluded. `stop()` is final (`isStopped`, timer invalidation, retry reset).
- **Resolved on**: 2026-10-21
- **Lesson**: An event tap must only consume what it acts on. Decide synchronously from synchronously available state.

### ~~B-025: Arrangement changes silently dissolved mirror sets~~
- **Cause**: `ArrangementService` wrote an explicit origin for every online display. Per `CGDisplayConfiguration.h`, setting the origin of a display that is mirroring another removes it from the mirroring set.
- **Fix**: Skip displays that are offline, that are mirroring (`CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay`), or whose origin is already within 1 px. `setAsMainDisplay` refuses a mirroring target, and `arrangeExternalAboveBuiltin` excludes mirroring displays from its layout maths.
- **Resolved on**: 2026-10-21
- **Lesson**: Do not write an origin for a mirror target; it is not an independent display.

### ~~B-024: The headless session flipped the main display back to the virtual display ~800 ms after restoring the physical one~~
- **Cause**: `ensureVirtualDisplayIsMain` restored the physical display when it came back online, but that change posted `didChangeScreenParametersNotification`, and the resulting reassert pass fell through to setting the virtual display main again.
- **Fix**: Added a `physicalIsDesignatedMain` latch (reset on start/stop/rollback). While it is set, the reassert only ensures the physical display is main, guarded by `CGDisplayIsMain(previous) == 0` so its own change produces no write and cannot fight itself; a dropped virtual display is still recreated.
- **Resolved on**: 2026-10-21
- **Lesson**: A notification caused by your own change must not trigger the opposite change.

### ~~B-023: Sleep/wake recovery was never installed unless the menu had been opened~~
- **Cause**: `AppDelegate.onWake` was assigned inside the `MenuBarExtra` content's `.task`. That content is built lazily, so a login-launch with no menu open left the handler nil and every wake recovery step was skipped.
- **Fix**: `DisplayManager` observes `NSWorkspace.didWakeNotification` itself (`setupWakeObserver()` in `init`, removed in `deinit`) and runs the sequence: 2 s settle → `refreshDisplays` → software brightness → gamma → saved resolution. AppDelegate keeps only the virtual-display reconcile; the SwiftUI `.task` only schedules the initial arrange.
- **Resolved on**: 2026-10-21
- **Lesson**: Never wire essential lifecycle work to SwiftUI view construction. `NunbitApp.body` now touches `displayManager` so the object is created at launch.

### ~~B-022: Connecting a 2K+ display silently wrote a privileged HiDPI plist (no consent, clobbered other tools)~~
- **Cause**: `DisplayManager.refreshDisplays` called `autoEnableHiDPIIfNeeded` for every newly seen display, which wrote `/Library/Displays/.../Overrides/...` via an administrator prompt, `cp`-overwriting any existing file and `rm -f`-deleting one it might not own. `NSAppleScript` also blocked the main actor during the password dialog.
- **Fix**: Gated behind `fd.hidpi.autoEnable` (default OFF, UI switch). Writes now merge — unknown keys are preserved and `scale-resolutions` is unioned. Ownership is recorded in `~/Library/Application Support/Nunbit/hidpi-overrides.json` (`createdFile`, `ourEntries`); a file is deleted only when this app created it, otherwise only our entries are removed. `isHiDPIEnabled` means "non-empty scale-resolutions", so another app's override is no longer reported as ours and shown as `.managedByOther`. The AppleScript moved to a detached task so the UI is not frozen, and temp files are cleaned up with `defer`.
- **Resolved on**: 2026-10-21
- **Lesson**: A privileged, persistent system change must be user-initiated and must never clobber another tool's file. "File exists" is not ownership.

### ~~B-021: Positive contrast did nothing~~
- **Cause**: `channelParams` used `contrast / 250.0` to push lo/hi apart, but both ends clamp to 0/1, so any positive contrast degenerated to the identity transfer function.
- **Fix**: Positive contrast now routes to the table path and applies a strictly monotonic S-curve, `y = x + k·(smoothstep(x) − x)` with `k = contrast/200`, to the gamma-shaped input before the `lo + (hi−lo)·x` mapping. Negative contrast is byte-for-byte unchanged. `quantize` is only applied below 256 levels.
- **Resolved on**: 2026-10-21
- **Lesson**: `CGSetDisplayTransferByFormula` cannot express a contrast increase — a table and an S-curve are required.

### ~~B-020: One transient DDC write failure permanently pinned a display to software dimming~~
- **Cause**: `ddcAvailable[displayID] = false` was sticky with no re-probe or expiry, so `refreshBrightness` early-returned forever and every later change took the gamma path.
- **Fix**: Replaced with a `DDCHealth` struct (everSucceeded, consecutiveFailures, lastFailure) plus a 20 s re-probe interval. A display that has ever succeeded is retried on the very next adjustment; only a display that has never succeeded is throttled, so a DDC-less monitor does not stall every drag. The software fallback is still applied immediately.
- **Resolved on**: 2026-10-21
- **Lesson**: Distinguish "definitively unsupported" from "this attempt failed". Never latch a transient failure.

### ~~B-019: The software-brightness factor was written once and never cleared → permanent double dimming~~
- **Cause**: `fd.softBrightness_<id>` was only ever set or loaded; nothing removed it, and the DDC-success path did not clear it. One transient failure left the display permanently darker than the slider claimed, across launches and wakes.
- **Fix**: New `clearSoftwareBrightness(for:)` removes both the in-memory factor and the persisted entry and re-applies the display's gamma state (via `GammaService.reapply`, or an identity ramp). It is wired into the DDC-write success path. A 100 % software write no longer persists a no-op factor.
- **Resolved on**: 2026-10-21
- **Lesson**: Any persisted "fallback" state needs an explicit exit path back to the normal path.

### ~~B-018: Closing the menu panel silently removed the ICC profile override and the software-brightness dimming~~
- **Cause**: `ImageAdjustmentView.onDisappear` (which fires on every menu-panel close because `MenuBarExtra` tears down its content) called `GammaService.resetSingleDisplay`, which reset the gamma table *and* removed the ColorSync custom-profile override, and un-dimmed a software-brightness display.
- **Fix**: `resetSingleDisplay` now resets the gamma table only; removing the ICC override moved to `GammaService.removeCustomColorProfileOverride(for:)`. `onDisappear` persists state only and never writes hardware. The explicit "Reset all" action resets gamma but leaves the profile alone and re-applies the software-brightness factor. `applyIdentity` ("pause") is scaled by the current software-brightness factor, so pausing no longer jumps to full brightness.
- **Resolved on**: 2026-10-21
- **Lesson**: View teardown must never mutate hardware state. One function must not own two unrelated resources.

### ~~B-017: Per-display settings were keyed by the volatile `CGDirectDisplayID`~~
- **Cause**: Brightness, contrast, gamma state, software brightness and saved resolutions were stored under `fd.<name>_<displayID>`. macOS can reassign that ID after sleep, reconnect or reboot, so the user's saved values silently stopped applying.
- **Fix**: All per-display keys are now anchored to `DisplayInfo.stableID(for:)` (the CoreGraphics display UUID, with a vendor/model/serial fallback) through `PerDisplayStore.key(_:for:)`, which also performs a lazy one-time migration from the legacy numeric keys. `DisplayInfo.displayUUID` delegates to the same helper so the two can never disagree.
- **Resolved on**: 2026-10-21
- **Lesson**: Never persist by an identifier the system is allowed to change.

### ~~B-004: HiDPI virtual display triggers the system mirroring UI + mouse movement stutter~~
- **Fix**: `CGConfigureDisplayMirrorOfDisplay` triggers hardware mirroring mode on Apple Silicon, which is a dead end. Switched to the same plist override approach as BetterDisplay: write `scale-resolutions` to `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-XXXX`, which requires administrator privileges (NSAppleScript); after enabling, reconnect the display for it to take effect. All mirroring-related code has been removed (enableHiDPIVirtual/disableHiDPIVirtual/hiDPIMirrorMap, etc.).
- **Resolved on**: 2026-03-05
- **Lesson**: There are only two HiDPI approaches on macOS: (1) plist override (the BetterDisplay approach, requires admin + reconnect) (2) a pure CGVirtualDisplay virtual display (does not mirror a physical screen). ❌ Never use CGConfigureDisplayMirrorOfDisplay.

### ~~B-002: CGVirtualDisplay is a private API with no public header~~
- **Fix**: The user approved use of the private API. Created Nunbit-Bridging-Header.h declaring the CGVirtualDisplay + IOAVService interfaces; VirtualDisplayService now implements full virtual display creation/destruction.
- **Resolved on**: 2026-03-03

### ~~B-003: DDC brightness control has no effect on some external displays~~
- **Fix**: Root cause confirmed: the IOFramebuffer I2C API used by DDCService does not work at all on Apple Silicon. Added the IOAVService ARM64 DDC path (locating external displays via DCPAVServiceProxy), plus a CGSetDisplayTransferByTable gamma table software brightness fallback.
- **Resolved on**: 2026-03-03

### ~~B-001: DisplayInfo.name only shows "Display N" instead of the real display name~~
- **Fix**: Use `IOServiceMatching("IODisplayConnect")` + `IODisplayCreateInfoDictionary` to enumerate all IODisplayConnect services, match by DisplayVendorID + DisplayProductID, and take the product name of the first locale from the DisplayProductName dictionary; the built-in display directly returns "Built-in Display"
- **Resolved on**: 2026-03-02
- **Lesson**: Integer values in IOKit CF dictionaries may be of type Int rather than UInt32, so both types must be attempted

### ~~B-000: Missing GENERATE_INFOPLIST_FILE causes build failure~~
- **Fix**: Added `GENERATE_INFOPLIST_FILE: YES` to project.yml settings
- **Resolved on**: 2026-03-02
- **Lesson**: xcodegen does not generate Info.plist automatically; it must be enabled explicitly

### ~~B-000b: DDCService static singleton Swift 6 concurrency error~~
- **Fix**: Marked the class `@unchecked Sendable` and set `SWIFT_STRICT_CONCURRENCY: minimal` in project.yml
- **Resolved on**: 2026-03-02
- **Lesson**: Under Swift 6 strict concurrency checking, singletons need an explicit Sendable marking
