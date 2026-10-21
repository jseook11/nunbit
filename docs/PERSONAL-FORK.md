# Personal Fork — Headless / Lecture Modes

> Branch: `personal/headless` · Base: upstream `main` (`07ba072`) · Work window: 2026-10-20 ~ 21

This document describes the changes and usage of a Nunbit fork built for personal use.
It is not intended as a PR to upstream — it is a branch that solves two situations on this Mac.

## Goals

1. **Keep lecture playback alive** — the Mac does not sleep and playback continues even when the physical monitor is off (or asleep).
2. **Idle games** — park a game window on a virtual display and keep it running with the physical monitor powered off.

## Usage

### Idle games (headless session)

1. Menu bar → **Virtual Displays**, create a `1920×1080` configuration. `HiDPI` can be on; keep `Auto` (autoCreate) off. (This fork ships with that configuration pre-seeded.)
2. Menu bar → **Headless Session**, select that virtual display and press **Start Headless Session**.
3. The session creates/activates the virtual display and makes it the main display.
4. Drag the game window onto the newly appeared virtual display.
5. Press the physical monitor's power button to turn it off. The game keeps rendering on the virtual display.
6. When you come back, power the monitor on and press **End Headless Session**. The previous main display is restored and the virtual display created by the session is removed.

> If you already had the virtual display turned on manually, you can move the game window first and then start the session. In that case the virtual display is not removed when the session ends.

> While a session is active, that virtual display cannot be turned off or deleted from the menu.
> If you power the physical monitor off and on again, the session restores the physical monitor as main so you can reach the menu. The game and session keep running on the virtual display. Turn the monitor off again and the virtual display becomes main again.

### Lectures (lecture mode)

1. Menu bar → open **Lecture Mode**.
2. Turn on **Keep Playing (Prevent System Sleep)**.
3. Press **Turn Off Display Now**, press the monitor's power button, or wait for display auto-sleep.
4. The system stays awake and playback continues. A key press or mouse movement powers the monitor back on.

> Lecture mode **does not create a virtual display.** FairPlay/HDCP protected video will not play on a virtual display.
> This mode only blocks system sleep and allows display sleep. (Same scope as `caffeinate -i`.)

## Implementation changes

### Stability / bug fixes

- Fixed the menu panel opening as an empty screen: give the `ScrollView` a definite height and apply `fixedSize` (the PR #9 approach).
- Fixed the external display arrangement being reset every time the menu opened:
  - Used the fact that `.task` on `MenuBarExtra` content runs every time to remove the repeated automatic arrangement.
  - Automatic arrangement now runs once per launch, and only debounced after add/remove/mode changes.
  - `setMainFlag` no longer triggers arrangement.
- Removed a use-after-free where `CGCancelDisplayConfiguration` was called after `CGCompleteDisplayConfiguration`.
- Merged multiple display moves into a single transaction.
- Changed main display switching from "swap the origins of two displays" to "translate the whole layout".
- `CGVirtualDisplay`:
  - `width/height` are logical points, `maxPixels` is 2× backing under HiDPI.
  - Poll `displayID`/online state for up to 5 seconds after `apply()`.
  - Generate a stable product/serial from the config UUID.
  - Removed the `CGDisplayIOServicePort == 0` heuristic (physical displays also report 0 on macOS 26).
- Fixed a `passRetained` leak in `CGEvent` pass-through → `passUnretained`.
- Validate the `mntr` + `RGB ` header before applying an ICC profile.
- Disabled the `CGSConfigureDisplayMode` fallback for mismatched types.
- Excluded virtual displays from automatic arrangement / presets / auto-HiDPI / unified brightness.
- Recreate the virtual display after wake (`reconcileActiveDisplays`).

### New features

- `SleepAssertionService` — prevention based on IOPM assertions, with a per-owner reference count.
  - `lecture`: `PreventUserIdleSystemSleep` only.
  - `headlessSession`: `PreventUserIdleSystemSleep` + `PreventUserIdleDisplaySleep`.
  - If the app dies the kernel releases the assertion automatically, so nothing lingers like a `caffeinate` child process.
- `HeadlessSessionService` — create/activate the virtual display → switch to main → prevention assertion → re-check main on display change → restore on exit.
- `LectureModeView` — prevention toggle + immediate screen-off button via `pmset displaysleepnow`.
- `HeadlessSessionView` — virtual display selection + start/end + status/errors.
- Added version metadata (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).

## Verification status

Completed a Debug build on Xcode 27.1 / macOS 26.7.1.

- `xcodebuild -project Nunbit.xcodeproj -scheme Nunbit -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
- Service/model layer: `swiftc -typecheck` passes.
- SwiftUI views: Xcode build passes. Additionally verified menu panel and new view layouts via offscreen `NSHostingView` capture.
  - The menu panel renders properly — display list, presets, tools, settings, and footer — instead of an empty screen.
  - The `Lecture Mode` and `Headless Session` rows and their inner controls are laid out correctly.
- Real hardware smoke test passed:
  - Created a 1920×1080 logical / 3840×2160 backing HiDPI virtual display.
  - vendor `0xEEEE`, stable model/serial, confirmed online.
  - Switched the virtual display to main → physical display moved to `(1280,0)`.
  - On exit, physical display restored to `(0,0)` as main and the virtual display removed.
  - Ran the real app and seeded an `autoCreate` config, confirming the app process creates/cleans up the virtual display.
  - `SleepAssertionService` owner reference count: lecture (system) + headless (system+display) → system retained after releasing headless → 0 after releasing everything.
- **Not verified**: whether a game/lecture actually keeps running with the physical monitor powered off. The user needs to test this once.

## Current install

- Build: Release, ad-hoc signed
- Install location: `~/Applications/Nunbit.app`
- Default virtual display config: `1920×1080` / HiDPI / 60Hz / autoCreate off
- The `Headless Session` selection is pre-set to that config as well

## Build

```bash
# After installing Xcode
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcodegen          # already installed
xcodegen generate
xcodebuild -scheme Nunbit -configuration Debug build

# Release + DMG
./build.sh
```

## Known limitations

- FairPlay/HDCP video does not play on a virtual display. Lecture mode keeps the physical display.
- Virtual displays are 60Hz SDR. VRR/120Hz is not supported.
- The app does not turn the physical monitor off via DDC. The user presses the monitor's power button.
- `pmset displaysleepnow` can pause video in some players. In that case, use the monitor's power button.
- This is a personal build without notarization.
