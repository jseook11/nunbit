# Nunbit — Claude Context Entry Point

> Version: 2026-03-05 | Status: Phase 22 complete

## What This Project Is

A free, open-source alternative to BetterDisplay. A macOS menu bar app that manages displays: DDC brightness/contrast control, resolution/HiDPI management, display arrangement, color management, virtual displays.
Tech stack: Swift 6 + SwiftUI (MenuBarExtra) + IOKit + CoreGraphics, zero third-party dependencies.

## Quick Navigation (load as needed)

| What you need to do | Which file to read |
|-----------|-----------|
| **Check blocking issues before starting** | `docs/BLOCKING.md` |
| Understand the code structure, find files | `docs/codemap/CLAUDE.md` (index) → `docs/codemap/file-tree.md` (file tree) → `docs/codemap/relationships.md` (relationship diagram) |
| View project planning and current progress | `docs/ROADMAP.md` (overview) → `docs/roadmap/phase-N.md` (details) |
| Review lessons learned / pitfalls | `docs/lessons/CLAUDE.md` (index) → `docs/lessons/{topic}.md` (details) |

## Current Focus

- **Current phase**: Phase 22 complete. Feature simplification (removed rotation/streaming/PiP/mirroring/config protection, etc.) + auto brightness rewrite + HiDPI plist override implementation.
- **Off-limits**: do not change the structure of `docs/roadmap/` (planner output), only update `[x]` progress markers
- **Recent changes**: Phase 21 feature simplification (removed 15+ files), Phase 22 auto brightness rewrite (CoreDisplay dlsym), HiDPI switched from the mirroring approach to plist override, arrangement center alignment fix, HiDPI presets

## Autonomous Decision Rules

> **Blocking first (the very first thing when starting work):**
- Every session → read `docs/BLOCKING.md` first → resolve any P0/P1 issues first → only work on the ROADMAP once all are cleared
- Ran into a problem you cannot solve → add it to `docs/BLOCKING.md`

> **Coupling rules:**
- Changed a `DisplayInfo` property → grep all reference sites and update them
- Changed `project.yml` → must run `xcodegen generate` to regenerate the xcodeproj
- Added a Service/View file → update `docs/codemap/file-tree.md`

> **Fixes/development:**
- Compile failure → fix it until it passes, do not skip it
- Swift 6 concurrency errors → use `@MainActor` or `@unchecked Sendable` (the project sets `SWIFT_STRICT_CONCURRENCY: minimal`)
- New files do not require changes to project.yml (xcodegen automatically includes every source file under Nunbit/)

> **SwiftUI component rules:**
- Row components that need local state (isHovered, isLoading) → must be a standalone `struct`, ❌ cannot be a `@ViewBuilder` function (@ViewBuilder functions do not support @State)
- Reusable row components use a consistent name: `XxxRow` (e.g. DetailRow, ExpandableRow, ProtectionRowView)

> **UserDefaults key naming convention:**
- All UserDefaults keys must carry the `fd.` prefix (e.g. `fd.launchAtLogin`, `fd.AutoBrightnessEnabled`)
- ❌ Bare keys (e.g. `"launchAtLogin"`) may collide with system or third-party keys

> **Coordination principle for shared resources written across Services:**
- Two Services must not each independently write the same CoreGraphics resource (e.g. gamma table) → designate one Service as the owner responsible for the final write
- BrightnessService (software brightness) writes the transfer function through GammaService and does not write CGSetDisplayTransferByTable directly
- ❌ Calling `CGSetDisplayTransferByFormula/Table` directly from the View layer (bypasses GammaService) → ✅ operate indirectly via `GammaService.apply()` or `GammaService.resetSingleDisplay()`
- ❌ `CGDisplayRestoreColorSyncSettings()` (global) → ✅ `GammaService.resetSingleDisplay(displayID)` resets only a single display

> **Sleep/wake handling (mandatory):**
- Services that write display hardware state (gamma, software brightness) must respond to `NSWorkspace.didWakeNotification` and re-apply
- Already registered: AppDelegate listens for wake → GammaService.reapplyIfNeeded + BrightnessService.reapplySoftwareBrightnessIfNeeded

> **C callback Unmanaged rules:**
- Long-lived C callbacks (CGDisplayRegisterReconfigurationCallback, etc.) → must use `Unmanaged.passRetained(self)`, `release()` on deregistration
- ❌ `passUnretained` (dangling pointer risk)

> **IOKit display matching:**
- Do not match IOKit services using CGDisplayVendorNumber/ModelNumber (unreliable on some displays)
- Use `NSScreen.localizedName` for the display name
- Use IOServiceGetMatchingServices to enumerate IODisplayConnect for IOKit service lookup (❌ CGDisplayIOServicePort is deprecated)
- DDC external brightness control is not always available → the UI must degrade gracefully (notify the user when detection fails)

> **Async principles:**
- Only make genuinely slow operations async (filesystem scans, network requests)
- Keep microsecond-level IOKit calls (name lookup, property reads) synchronous; they are not worth making async

> **CGVirtualDisplay private API (mandatory):**
- `vendorID` must be non-zero (e.g. `0xEEEE`); when it is 0, `CGVirtualDisplay(descriptor:)` returns nil
- `CGVirtualDisplay(descriptor:)` must be called on the main thread (returns nil on a background thread); `apply(settings)` may run in the background
- Bridging header property names follow Chromium's `virtual_display_mac_util.mm` (`maxPixelsWide`/`maxPixelsHigh`, not `maxPixelSize`)

> **HiDPI implementation approach (mandatory):**
- ❌ `CGConfigureDisplayMirrorOfDisplay` for HiDPI — triggers hardware mirroring mode + mouse stutter on Apple Silicon
- ✅ Plist override written to `/Library/Displays/Contents/Resources/Overrides/` — the same approach BetterDisplay uses
- Writing the plist requires administrator privileges → use `NSAppleScript("do shell script ... with administrator privileges")`
- ❌ Setting `DisplayProductName` in the plist — overrides the system display name
- After enabling, the display must be reconnected for it to take effect (IOServiceRequestProbe is not always reliable)

> **Private framework dynamic loading:**
- ❌ Referencing private framework symbols with `@_silgen_name` (undefined symbol at link time)
- ✅ Runtime loading with `dlopen` + `dlsym` (e.g. CoreDisplay_Display_GetUserBrightness)

> **Stop and ask the user:**
- Needing to use a private API (CoreDisplay, etc.)
- Needing SIP disabled or special system permissions
- Architecture direction change (MVVM → something else)

> **Self-maintenance rules:**
- Adding/removing/modifying files → update `docs/codemap/file-tree.md`
- Completed a Phase task → mark `[x]` in `docs/roadmap/phase-N.md` **and also mark `[x]` in `docs/ROADMAP.md`** (progress is tracked from the latter)
- Hit a pitfall → write it to `docs/lessons/{topic}.md` (and update the `docs/lessons/CLAUDE.md` index)
- Discovered a preference/pattern → record it in this file's decision rules
- Got stuck → add it to `docs/BLOCKING.md`
- Resolved a BLOCKING issue → move it to the resolved section

## Verification Chain (must run after every change)

```bash
# 1. Compile check
xcodebuild -scheme Nunbit -configuration Debug build 2>&1 | tail -5

# 2. Coupling check (when interfaces/models change)
grep -r "DisplayInfo\|DisplayManager\|DDCService" Nunbit/ --include="*.swift" | grep -v "^Binary"
```

## Common Operations Playbook

### Adding a New Feature Section (the most common operation in Phases 2-12)
1. Create a new Service in `Services/` (e.g. `BrightnessService.swift`)
2. Create the corresponding View in `Views/` (e.g. `BrightnessSliderView.swift`)
3. If state management is needed, create a ViewModel in `ViewModels/`
4. Embed the new View in `MenuBarView.swift`
5. Update `DisplayInfo.swift` to add the required properties
6. Run the verification chain

### Implementing a DDC Feature
1. Implement IOKit I2C communication in `DDCService.swift`
2. Look up the VCP code for the new feature in the DDC/CI standard (e.g. 0x10 = brightness)
3. Call `DDCService.shared.read/write` from the Service
4. Run the verification chain + manually test on a real external display

### Fixing a Bug
1. Determine whether it is a compile error or a runtime error
2. Compile error → inspect the xcodebuild output to locate it
3. Runtime error → check logs in Console.app or use the Xcode debugger
4. Fix → run the verification chain

## Design Resources

- **App icon design**: use [Nano Banana](https://nano-banana.ai/) (an AI image generator powered by Google Gemini) to produce high-quality icons
  - Supports generating icons, logos, and UI elements from text descriptions
  - After generation, use Python PIL to crop/scale into the multi-size PNGs macOS requires (16/32/64/128/256/512/1024)
  - Icon files live in `Nunbit/Assets.xcassets/AppIcon.appiconset/`

## Key Conventions

- **Language**: Swift 6.0 (concurrency checking minimal)
- **Minimum OS**: macOS 14.0
- **Architecture**: MVVM (View → ViewModel → Service)
- **Build**: `xcodegen generate && xcodebuild -scheme Nunbit -configuration Debug build`
- **No Sandbox**: entitlements have App Sandbox disabled (required for DDC/IOKit)
- **No third-party dependencies**: everything uses system frameworks

## Core Frameworks

| Framework | Purpose | Phase |
|------|------|-------|
| CoreGraphics | Display enumeration, resolution, arrangement | 1-4 |
| IOKit | DDC/CI I2C communication, brightness/contrast | 2 |
| ColorSync | ICC Profile management | 5 |
| CoreGraphics (CGVirtualDisplay) | Virtual display | 10 |
| CoreDisplay (dlsym) | Built-in display brightness reading | 22 |
