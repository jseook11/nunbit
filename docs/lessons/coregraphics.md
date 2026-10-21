# Lessons Learned — CoreGraphics

> Updated: 2026-03-05

## CoreGraphics / Displays

- In a Swift 6 class init, if a `@Published` property is not yet initialized, you cannot use `self.anyProperty` before initialization completes (even if that property has already been assigned) → fix: store the value in a local variable and reference that
- `CGDisplayRegisterReconfigurationCallback` requires the callback to be a C function pointer (a global func), not a closure → pass `Unmanaged.passUnretained(self).toOpaque()` via `userInfo`
- Under Swift 6, `deinit` is nonisolated and cannot access `@MainActor`-isolated properties → fix: mark the properties that need to be accessed in deinit as `nonisolated(unsafe)`
- If compilation reports "symbol not found" after adding a new Swift source file, you need to re-run `xcodegen generate` to regenerate the xcodeproj (even if project.yml uses globs, the old xcodeproj may not include the new file)
- The macOS 26.2 SDK replaces the C functions `CGDisplayModeGetWidth/Height/PixelWidth/PixelHeight/RefreshRate/IODisplayModeID` etc. with Swift properties (`mode.width`, `mode.pixelWidth`, `mode.ioDisplayModeID`, etc.) and methods (`mode.isUsableForDesktopGUI()`) → when using the new SDK, use the property syntax directly to avoid deprecated functions
- `kCGDisplayShowDuplicateLowResolutionModes: true` is the correct key name; passing it in the options dictionary of `CGDisplayCopyAllDisplayModes` exposes HiDPI scaled modes
- `CGDisplayCopyColorSpace` returns a non-Optional `CGColorSpace` in the macOS 26 SDK (older SDKs returned Optional) → change `guard let` to a direct call, and get the name via `colorSpace.name` (`CGColorSpaceCopyName` has been replaced by a property)
- `CGDisplayMode.pixelEncoding` is `CFString?` (not `String`), so it must be bridged manually: `if let cfEnc = mode.pixelEncoding { encoding = cfEnc as String }`
- ColorSync global constants (`kColorSyncDisplayDeviceClass`, `kColorSyncDeviceDefaultProfileID`) are of type `Unmanaged<CFString>?` in Swift 6, and accessing global vars produces a concurrency-safety warning → suppress the concurrency error with `@preconcurrency import ColorSync`; when accessing, use `.takeUnretainedValue()` to borrow the reference (do not use `takeRetainedValue`, to avoid a double free)
- `kColorSyncProfileUseSystemSequence` does not exist in the public ColorSync headers → the API to reset to the system default profile cannot be implemented through public interfaces; skip resetProfile
- After adding a new Swift source file you must re-run `xcodegen generate` to regenerate the xcodeproj, otherwise the compiler will not know about the new file ("cannot find in scope" error)

## HiDPI / Resolution

- After `HiDPIService` writes a display override plist, macOS does not load the new mode immediately → you need to trigger display re-enumeration (`CGDisplayForceToMirror` or `IOServiceRequestProbe`)
- `isUsableForDesktopGUI()` filters out some resolution modes, causing certain resolutions to be "invisible" → you may need to bypass this filter

### L-006: On macOS 14+, plist injection cannot dynamically enable HiDPI
- **Symptom**: After writing a display override plist + IOServiceRequestProbe, a 2K external display still does not show HiDPI modes
- **Cause**: macOS Ventura/Sonoma does not dynamically re-enumerate plist-injected modes for an already-connected display. The plist approach only works when the display is connected for the first time
- **Fix**: Use the private CGVirtualDisplay API to create a 3840x2160 virtual display (hiDPI=1), then mirror the physical display to the virtual display; macOS then automatically offers HiDPI modes such as 1920x1080@2x
- **Lesson**: The core of BetterDisplay's HiDPI approach is "virtual display + mirroring", not plist injection
- **Date**: 2026-03-03

### L-007: NSWindow.isReleasedWhenClosed defaults to true
- **Symptom**: The app crashes/hangs when the notch overlay window is closed
- **Cause**: NSWindow defaults to `isReleasedWhenClosed = true`; after close() the window is immediately released by ARC, leaving a dangling pointer in the dictionary
- **Fix**: Set `isReleasedWhenClosed = false` immediately after creating the NSWindow
- **Lesson**: The other windows in the project (PiPWindow, StreamWindow, VideoFilterWindow) all set this property correctly; only NotchOverlayManager missed it
- **Date**: 2026-03-03

## CGVirtualDisplay / Virtual Displays

- `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` are private CoreGraphics SPI. Although the symbols are exported in the TBD file (`grep CGVirtualDisplay CoreGraphics.tbd`), they are not declared in the public C/ObjC headers or the Swift interface files of the macOS 26 SDK → referencing them directly in Swift reports a "cannot find type in scope" error
- BetterDisplay/BetterDummy use these classes by declaring their own private interface header (bridging header) → this is private API usage, and the project needs an explicit decision on whether to accept the risk
- If you are asked to continue only after this is resolved, read BLOCKING.md B-002 first

### L-020: CGVirtualDisplay vendorID must be non-zero
- **Symptom**: `CGVirtualDisplay(descriptor:)` always returns nil, with no error
- **Cause**: `vendorID = 0` is rejected by WindowServer; the node-mac-virtual-display project uses `0xEEEE`
- **Fix**: Set `vendorID = 0xEEEE`, `productID = 0x0001`, `serialNum = 0x0001`
- **Lesson**: Private APIs have implicit constraints that are undocumented; you must refer to a known-working open-source implementation
- **Date**: 2026-03-04

### L-021: CGVirtualDisplay(descriptor:) must run on the main thread
- **Symptom**: Calling it from a background DispatchQueue returns nil; calling it on the main thread succeeds
- **Cause**: WindowServer IPC requires CGVirtualDisplay initialization to happen on the main thread
- **Fix**: Build the descriptor + init on @MainActor; run `apply(settings)` and `enableMirror` in the background via `runWithTimeout`
- **Lesson**: Different methods of the same API may have different threading requirements
- **Date**: 2026-03-04

### L-022: Bridging-header property names must match the runtime API exactly
- **Symptom**: `-[CGVirtualDisplayDescriptor setMaxPixelSize:]: unrecognized selector` causes a crash
- **Cause**: The bridging header declared `maxPixelSize` (CGSize), but the actual property names are `maxPixelsWide`/`maxPixelsHigh` (uint32_t)
- **Fix**: Use Chromium's `virtual_display_mac_util.mm` as the authoritative reference and verify each property name one by one
- **Lesson**: You cannot guess property names in a private API bridging header; you must refer to reverse engineering or a known-working implementation
- **Date**: 2026-03-04

### L-023: HiDPI virtual display configurations must not use autoCreate
- **Symptom**: Every app restart, stale virtual displays accumulate (displayID=7,8,9,10...), and eventually creation fails
- **Cause**: The HiDPI config was stored in the configs array with `autoCreate: true`, but autoCreate only creates the virtual display without mirroring, causing useless virtual displays to accumulate
- **Fix**: Keep HiDPI configuration purely at runtime (`autoCreate: false`, not stored in configs), and clean up leftovers at startup
- **Lesson**: Configurations that depend on runtime state (such as the mirroring relationship) should not be rebuilt automatically — a rebuild lacks critical context
- **Date**: 2026-03-04

### L-024: CGDisplayMirrorsDisplay() detection is unreliable
- **Symptom**: Switching resolution fails in HiDPI mode; `CGDisplayMirrorsDisplay(physicalID)` returns `kCGNullDirectDisplay`
- **Cause**: macOS's mirror detection API cannot always recognize mirror relationships set via `CGConfigureDisplayMirrorOfDisplay`
- **Fix**: Add `VirtualDisplayService.virtualDisplayID(for:)` as a fallback in `resolvedTargetDisplayID()`
- **Lesson**: System API behavior may differ from the documentation, so a fallback is needed
- **Date**: 2026-03-04

### L-025: Choosing a HiDPI approach — mirroring is a dead end, plist override is the right way
- **Symptom**: Using CGConfigureDisplayMirrorOfDisplay to mirror an external display onto a virtual display in order to obtain HiDPI modes triggered the system "screen mirroring" UI + mouse stutter when crossing screens + pure mirror mode
- **Cause**: Apple Silicon's WindowServer manages hardware mirroring strictly; CGConfigureDisplayMirrorOfDisplay triggers the full mirror reconfiguration flow
- **Fix**: Switch to a plist override (writing to /Library/Displays/Contents/Resources/Overrides/), which is BetterDisplay's approach. Requires administrator privileges (NSAppleScript "with administrator privileges"); it takes effect after reconnecting the display
- **Lesson**: Do not use CGConfigureDisplayMirrorOfDisplay for HiDPI; on Apple Silicon it is a dead end

### L-026: Loading private framework symbols — dlsym instead of @_silgen_name
- **Symptom**: Declaring the private function with @_silgen_name("CoreDisplay_Display_GetUserBrightness") compiles but fails to link (undefined symbol)
- **Cause**: @_silgen_name requires the symbol to be visible at link time, and CoreDisplay is a private framework that is not on the default link path
- **Fix**: dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) + dlsym to load at runtime
- **Lesson**: Always use dlopen+dlsym for private framework symbols; do not use @_silgen_name

### L-027: display.pixelWidth is the current resolution, not the native resolution
- **Symptom**: The scale-resolutions array in the HiDPI plist override is empty
- **Cause**: display.pixelWidth/pixelHeight (from CGDisplayPixelsWide/High) were passed in as the native resolution, but the display may currently be at a non-native resolution
- **Fix**: Use display.availableModes.max(by: width*height) to get the largest available mode as the native resolution
- **Lesson**: CGDisplayPixelsWide/High returns the pixel dimensions of the current mode, not the panel's physical resolution

### L-028: CGVirtualDisplay dimensions are "logical dimensions", not backing pixels
- **Symptom**: After passing `width=1920, height=1080, hiDPI=1`, the system only offers a 960×540 HiDPI mode, or the mode list is empty
- **Cause**: `CGVirtualDisplayDescriptor.maxPixelsWide/High` is the **backing store limit**, while `CGVirtualDisplayMode`'s width/height are the **logical resolution**. A HiDPI display's backing is twice the logical size, so 1920×1080 logical requires `maxPixels = 3840×2160`, and modes must provide both logical 1920×1080 and backing 3840×2160
- **Fix**:
  ```swift
  descriptor.maxPixelsWide = UInt32(hiDPI ? logicalWidth * 2 : logicalWidth)
  settings.hiDPI = hiDPI ? 1 : 0
  settings.modes = [
      CGVirtualDisplayMode(width: logicalWidth, height: logicalHeight, refreshRate: rate),
      CGVirtualDisplayMode(width: backingWidth, height: backingHeight, refreshRate: rate)
  ]
  ```
- **Verification**: On macOS 26.7.1, creating a 1920×1080 logical display reads back a `CGDisplayMode` of `1920×1080 pixel 3840×2160` and a `CGDisplayBounds` of 1920×1080
- **Lesson**: The semantics of `width/height` in a private API depend on the struct field; do not mix logical dimensions with pixel dimensions
- **Date**: 2026-10-20

### L-029: displayID is not immediately available after apply()
- **Symptom**: `create()` checks `displayID != kCGNullDirectDisplay` right after `apply(settings)`, and fails randomly
- **Cause**: When `apply()` returns, WindowServer has only finished committing the configuration; the displayID and mode list are populated asynchronously
- **Fix**: Poll `displayID` + `CGDisplayIsOnline` for up to 5 seconds (50ms interval); only write to `activeDisplayObjects` after confirming online
- **Lesson**: A synchronous return from a private API only means the request was accepted, not that the resource is already available
- **Date**: 2026-10-20

### L-030: CGCancelDisplayConfiguration must not be called after Complete
- **Symptom**: Occasional crashes (EXC_BAD_ACCESS) when arranging displays, especially when `CGCompleteDisplayConfiguration` returns failure
- **Cause**: `CGCompleteDisplayConfiguration` consumes and releases the `CGDisplayConfigRef` whether it succeeds or fails; calling `CGCancelDisplayConfiguration` afterward is a use-after-free
- **Fix**: Only Cancel when a `CGConfigure...` call failed and Complete has not yet been called; after Complete, just return the result. When arranging multiple displays, commit everything in a single transaction to avoid intermediate states triggering a storm of reconfiguration callbacks
- **Lesson**: Begin/Complete/Cancel is a strict ownership protocol; after Complete the config must always be treated as invalid
- **Date**: 2026-10-20

### L-031: CGDisplayIOServicePort returns 0 for physical displays on macOS 26
- **Symptom**: Identifying virtual displays by "servicePort == 0" ended up treating physical displays as virtual ones, breaking all autoCreate logic
- **Cause**: On macOS 26, `CGDisplayIOServicePort` returns `MACH_PORT_NULL` for some physical displays (such as Apple Silicon external HDMI/DP)
- **Fix**: Identify your own virtual displays using `CGDisplayVendorNumber == 0xEEEE` plus stable `productID/serialNum` derived from the config UUID; do not use the service port to tell virtual from physical
- **Lesson**: Any heuristic of the form "returns 0 means virtual" will break with OS versions; prefer a stable identity that you wrote yourself
- **Date**: 2026-10-20

### L-036: Any display-configuration change resets the transfer table of *every* display
- **Symptom**: With a colour adjustment saved and brightness set low, activating a virtual display made the physical monitor brighter; it only went back when the user opened that display's Image Adjustment panel
- **Cause**: WindowServer discards the gamma transfer table of all displays whenever the configuration changes. Measured on macOS 26: a display at `lo=0.04 / hi=0.96` reads back `lo=0 / hi=1` immediately after a `CGVirtualDisplay` is created, and again after it is destroyed. It is *not* limited to the display that changed, and it is *not* reported as a mode change — an empty `CGBeginDisplayConfiguration` → `CGConfigureDisplayOrigin` → `CGCompleteDisplayConfiguration` transaction does **not** trigger it, only add/remove does
- **Fix**: `DisplayManager.scheduleDisplayStateRestore()` re-applies software brightness and gamma for every online display after any configuration change, triggered by both the CoreGraphics reconfiguration callback (which does fire for a virtual display add/remove, with `.addFlag` 0x111a / `.removeFlag` 0x1220) and `NSApplication.didChangeScreenParametersNotification`. Three passes (0.05 s, 0.25 s, 1.2 s) because a write issued while the transaction is still committing is silently dropped — the reset lands ~0.2 s after the display appears, and the passes are what decide how fast it ends (measured with a 20 ms gamma sampler: ~200 ms of visible brightening with a single 0.15 s pass, ≤20 ms with three)
- **Lesson**: An OS-initiated reset of shared hardware state is silent and permanent; recovery has to be an explicit re-assert pass keyed to the event that causes it, not something a view does when it happens to appear
- **Date**: 2026-10-21

### L-037: "HiDPI enabled" is a property of the display, not of the plist override
- **Symptom**: A 4K display running "looks like 2560×1440" with a 5120×2880 backing showed the HiDPI row as disabled, and enabling it moved the display to another resolution
- **Cause**: The row derived its state from whether Nunbit had written a plist override in `/Library/Displays/...`. macOS already offers HiDPI modes natively for every 4K+ panel, so the override was redundant — inert until the next reconnect, and its mode re-enumeration could land the display on `native × 2` backing (7680×4320 on a 4K panel), a resolution the user never picked
- **Fix**: Derive the state from the display itself (`availableModes.contains { $0.isHiDPI }` and `currentDisplayMode?.isHiDPI`). When macOS provides HiDPI, the toggle switches between the HiDPI and non-HiDPI mode of the **same logical resolution**; the plist override is kept only for displays with no HiDPI mode at all, and an override Nunbit wrote for a display that no longer needs one is reported and removable
- **Lesson**: A toggle must report the state of the thing the user cares about, not the state of the mechanism the app happens to use. Also: never write a privileged, reconnect-scoped override when the OS already provides the capability
- **Date**: 2026-10-21

### L-034: "The override file exists" does not mean this app created it
- **Symptom**: Turning HiDPI off in the UI would have deleted an override that another display tool had written, and turning it on `cp`-overwrote every other key in an existing file (including that tool's scaled modes and metadata)
- **Cause**: Ownership was inferred from the existence of `.../Overrides/DisplayVendorID-x/DisplayProductID-y`. Several tools write that same path, and a file may contain keys or modes this app never produced. `isHiDPIEnabled` was "a file exists", so a foreign override was displayed as ours and its toggle-off ran `rm -f`
- **Fix**: Merge instead of replace — read the existing plist, keep every unknown key and union `scale-resolutions`. Record what this app actually created in `~/Library/Application Support/Nunbit/hidpi-overrides.json` (`createdFile`, `ourEntries`, keyed `vendor-product`); delete the file only when `createdFile` is true, otherwise remove only our entries. Report a foreign override as `.managedByOther` and make the toggle a no-op. "Enabled" now means "a non-empty `scale-resolutions` array", not "a file exists"
- **Lesson**: A shared, privileged on-disk location needs an explicit ownership record. Inferring ownership from existence is how one display tool destroys another's configuration
- **Date**: 2026-10-21
