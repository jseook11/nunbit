# Nunbit

> **A free, open-source display manager for macOS.** Brightness, resolution, HiDPI, color and virtual displays — from the menu bar, with zero third-party dependencies.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](project.yml)

Nunbit is a free alternative to [BetterDisplay](https://github.com/waydabber/BetterDisplay). It is not a feature-for-feature clone — it concentrates on the display controls you actually use every day, and tries to get the details right instead of adding more panels.

[Download Latest Release](https://github.com/jseook11/nunbit/releases/latest) · [Report an Issue](https://github.com/jseook11/nunbit/issues)

---

## What Nunbit Focuses On

**1. Brightness that actually reaches the right panel.**
Hardware DDC/CI when the monitor supports it, the private DisplayServices API for the built-in panel, and software gamma only as a last resort. The UI tells you which path is active instead of pretending they are the same thing. Brightness keys work on external displays and show the real macOS OSD.

**2. Settings that survive.**
Every display setting is keyed to the display's stable UUID, not the `CGDirectDisplayID` that macOS reassigns after sleep or reconnect. Brightness and gamma are restored after wake, hot-plug and resolution changes, and the UI is seeded with the real value before the first frame — no 50% flash when a panel opens.

**3. HiDPI without breaking the layout.**
Nunbit first asks macOS for HiDPI modes it already provides. It writes a display override only for panels that have none, and it never moves the display to a resolution you did not pick. Turning HiDPI off restores the exact same logical resolution at 1×.

**4. A small, honest app.**
Menu-bar only, no Dock icon, zero third-party dependencies, no telemetry, no background daemons. Features that added complexity without being useful — rotation, screen streaming, picture-in-picture, mirroring, configuration protection — were deliberately removed. Private APIs are used only where there is no public alternative, and each is isolated behind a service so it can be replaced when macOS changes.

---

## Features

### Brightness

- **Hardware brightness (DDC/CI)** for external monitors over IOKit I2C (Intel) or IOAVService (Apple Silicon), with per-display EDID matching so two identical panels never get each other's controls.
- **Built-in display brightness** through the private DisplayServices framework. This is the path that still works on macOS 26, where the old IOKit `IODisplayConnect` route no longer reaches the internal panel.
- **Software brightness fallback** via the gamma table when a monitor has no DDC support, with smooth animated transitions.
- **Brightness keys for external displays** — a `CGEventTap` routes the native brightness keys to the display under the mouse cursor and shows the genuine macOS OSD through `OSDUIHelper`.
- **Auto Brightness** — the built-in panel's brightness (including macOS's own auto-brightness) is mirrored proportionally to physical external displays. Configurable sync ratio; a manual change buys a 30-second cooldown. Hidden when there is no built-in panel or no external display.
- **Combined brightness** — one slider that drives every physical display at once. Follows changes made elsewhere (individual sliders, System Settings, keys, monitor buttons) instead of freezing at its first value.

### Resolution, HiDPI and Layout

- **Every available mode** per display, including HiDPI and scaled modes, with the current mode shown in the list.
- **HiDPI toggle** that understands the difference between macOS-provided HiDPI modes and an administrator-level plist override. An override written by another app is labelled as such and never touched.
- **Display arrangement editor** — drag displays to position them, or auto-arrange external displays above the built-in panel.
- **Set as main display**, with the whole layout translated in a single CoreGraphics transaction.
- **Display presets** — built-in *HiDPI* and *Native* presets plus user-named presets that capture each external display's resolution, HiDPI state, brightness and arrangement. One click to apply; the built-in screen is never touched.

### Color and Image

- **ICC profile management** per display via ColorSync, showing the real active profile and only that display's profiles (no duplicate-looking entries from monitors macOS has seen before).
- **Image Adjustment** — contrast, gamma, gain, color temperature, per-channel gamma/gain and quantization, all through one owner of the gamma table. Optional warning when HDR content is on screen.

### Virtual Displays and Sessions

- **Virtual displays** created with the private `CGVirtualDisplay` API: logical size, HiDPI backing, refresh rate, persistent configurations and auto-create on launch.
- **Headless Session** — makes a virtual display the main display and holds a sleep assertion, so an idle game or app keeps rendering while the physical monitor is switched off. Restores the previous main display on stop.
- **Lecture Mode** — blocks system sleep while letting the display sleep, without creating a virtual display, so FairPlay/HDCP-protected video keeps playing.
- **Wake and hot-plug recovery** — virtual displays are reconciled after wake, and gamma, software brightness and saved resolutions are re-applied after any display configuration change.

### Menu Bar Convenience

- Per-display expandable panels that remember which sections you left open.
- **Hide the MacBook notch** with an overlay that follows display configuration changes.
- **Launch at Login** through `SMAppService`.
- **Update check** against GitHub Releases at launch (optional, no telemetry).
- **No Dock icon, no sandbox** — a single menu-bar app with no helper processes.

---

## Performance and Reliability

Measured on the development machine — point measurements, not a whole-app benchmark. The details live in the commit history and `docs/lessons/`.

| Area | Before | Now |
|------|--------|-----|
| Image Adjustment panel opening | 11–15 ms to build five native sliders (peaks ~66 ms) | ~1.6 ms with a lightweight custom slider |
| Bright blip after a display change | ~200 ms of visible brightening with one restore pass | ≤20 ms with three passes (20 ms gamma sampler, 4 runs) |
| Dragging one Image Adjustment slider | rebuilt all 13 rows | only the affected row updates |
| Identical external monitors | DDC controls could be swapped | matched by EDID |
| Built-in brightness on macOS 26 | unreachable through IOKit | DisplayServices path |

Behind those numbers:

- The Image Adjustment panel renders from an in-memory cache on the first frame and no longer re-applies the gamma table when it appears — display-state restoration is owned by `DisplayManager`, which also re-applies after wake and hot-plug.
- Brightness sliders read the real panel value before the first frame, so the menu never flashes the default 50% before settling.
- ColorSync device lookup and ICC parsing run off the main actor, so opening the Color Profile panel does not stall the menu.
- Auto Brightness publishes a new reading only when it changes by 0.5% or more; combined brightness polls once per second only while its panel is visible.
- Per-display settings are keyed by the stable UUID, and the FreeDisplay → Nunbit migration is additive — it copies only keys the new domain is missing, so it cannot resurrect stale values.

See [CHANGELOG.md](CHANGELOG.md) for the complete list of fixes.

---

## How It Compares

| Capability | Nunbit | Notes |
|------------|:------:|-------|
| DDC/CI brightness | ✅ | IOKit I2C and IOAVService, matched by EDID |
| Built-in brightness | ✅ | DisplayServices; IOKit/CoreDisplay fallbacks |
| Software brightness fallback | ✅ | Gamma table, smooth transitions |
| Brightness keys → external display | ✅ | Native macOS OSD included |
| Auto brightness sync | ✅ | Follows the built-in panel |
| Combined brightness slider | ✅ | All physical displays at once |
| Resolution switching | ✅ | All modes, including HiDPI |
| HiDPI toggle | ✅ | Native modes first, override only when needed |
| Display arrangement | ✅ | Drag editor + auto-arrange |
| Set main display | ✅ | |
| ICC profile switching | ✅ | |
| Image adjustment | ✅ | Software gamma, per-channel controls |
| Display presets | ✅ | Built-in and user-defined |
| Virtual displays | ✅ | `CGVirtualDisplay`, persistent configs |
| Headless / lecture sessions | ✅ | |
| Notch hiding | ✅ | |
| Launch at login | ✅ | |
| Rotation | ❌ | Removed deliberately |
| Screen mirroring / streaming / PiP | ❌ | No user-facing UI; internal mirroring only builds virtual displays |
| EDID override | ❌ | Requires SIP disabled |
| XDR / HDR extra brightness | ❌ | Hardware-specific |
| Notarized build | ❌ | Builds are ad-hoc signed |

---

## Installation

**Requires macOS 14 (Sonoma) or later.** Works on Apple Silicon and Intel.

### Download

1. Download `Nunbit.dmg` from [Releases](https://github.com/jseook11/nunbit/releases/latest).
2. Open the DMG and drag **Nunbit.app** to **Applications**.
3. First launch: right-click the app → **Open**. The build is not notarized, so Gatekeeper asks once.

### Build from Source

With full Xcode installed:

```bash
git clone https://github.com/jseook11/nunbit.git
cd nunbit
brew install xcodegen
xcodegen generate
xcodebuild -scheme Nunbit -configuration Release build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

`project.yml` pins the maintainer's `DEVELOPMENT_TEAM`. Either replace it with your own team ID, or keep the signing flags above.

With only the Command Line Tools installed, use the local build script. It compiles every source file with `swiftc`, assembles the app bundle and ad-hoc signs it:

```bash
./scripts/build-local.sh --run            # build, install to /Applications, launch
./scripts/build-local.sh --debug --run    # -Onone -DDEBUG with print() diagnostics
```

Because the app is ad-hoc signed, macOS may ask you to re-approve Accessibility permission after each rebuild.

---

## Permissions

| Permission | When it is needed |
|------------|-------------------|
| **Accessibility** | Only for intercepting brightness keys. The app works without it; keys just won't be routed to external displays. |
| **Administrator approval** | Only when writing a HiDPI display override into `/Library/Displays` for a panel that has no HiDPI mode. |

No internet access is required. The only network request is the optional update check against the GitHub Releases API.

---

## How It Works

- **External monitors** — DDC/CI over I2C. On Apple Silicon, the AV service is matched to the display by EDID; on Intel, the framebuffer service is used directly.
- **Built-in display** — `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` from the private DisplayServices framework, loaded with `dlopen`/`dlsym`. CoreDisplay and IOKit are kept as fallbacks.
- **Software brightness and image adjustment** — one gamma transfer table per display, owned exclusively by `GammaService`. Contrast, color temperature and per-channel controls are folded into the same table.
- **Brightness keys** — a `CGEventTap` reads the native brightness key events. Events are consumed only when the cursor is on an external display; the built-in display keeps macOS's default handling.
- **Auto Brightness** — polls the built-in panel every two seconds and mirrors changes above a 2% threshold to external displays, scaled by the sync ratio.
- **HiDPI** — if macOS already lists a HiDPI mode at the current logical resolution, the toggle just switches modes. Otherwise Nunbit writes a display override plist and asks for a reconnect.
- **Virtual displays** — `CGVirtualDisplay` private API. `vendorID` is non-zero, creation happens on the main thread, and the display ID is resolved by polling after `apply()`.

---

## Tech Stack

- **Swift 6** + **SwiftUI** (`MenuBarExtra`) + AppKit
- **IOKit** — DDC/CI I2C and display services
- **CoreGraphics** — display enumeration, modes, arrangement, gamma
- **ColorSync** — ICC profile enumeration and switching
- **CGVirtualDisplay** — virtual displays (private API)
- **DisplayServices** / **CoreDisplay** — built-in panel brightness (private APIs, `dlopen`)
- **OSDUIHelper** — native brightness OSD (private XPC service)
- **SMAppService** — launch at login

No third-party packages.

---

## Project Structure

```
Nunbit/
├── App/          # AppDelegate, MenuBarExtra entry point
├── Models/       # DisplayInfo, DisplayMode, DisplayPreset
├── Services/     # DDC, brightness, gamma, resolution, HiDPI, arrangement, …
├── Utilities/    # Small extensions
└── Views/        # SwiftUI panels, one per feature
scripts/          # Local build, DMG packaging, release
docs/             # Code map, roadmap, lessons learned
```

Architecture is MVVM with the Service layer owning every system call. Views never write CoreGraphics state directly; gamma writes go through `GammaService`, brightness through `BrightnessService`.

---

## Known Limitations

- Private APIs can change between macOS releases. CoreDisplay, DisplayServices, OSDUIHelper and CGVirtualDisplay are the fragile parts; each is isolated so it can be replaced.
- Virtual displays are SDR at 60 Hz. DRM/FairPlay video will not play on them — use Lecture Mode instead.
- DDC support is monitor-dependent. When a panel cannot answer reads, Nunbit assumes a 0–100 range and tells you the control is software-based.
- Image Adjustment is a gamma-table effect, not a hardware calibration. It applies to SDR content and warns when HDR is active.
- Builds are ad-hoc signed and not notarized.

---

## Contributing

Issues and pull requests are welcome.

- Add **no third-party dependencies** — the project uses system frameworks only.
- The Xcode project is generated: edit `project.yml`, then run `xcodegen generate`.
- Keep the MVVM boundaries: View → Service → system framework.
- Match the existing Swift 6 style (`SWIFT_STRICT_CONCURRENCY: minimal`).
- Build with the signing flags shown above, or use `./scripts/build-local.sh` when Xcode is not available.

---

## License

MIT License — see [LICENSE](LICENSE).

---

## Acknowledgments

- Started as a rename of [FreeDisplay](https://github.com/huberdf/FreeDisplay) (MIT). Thanks to its contributors.
- Inspired by [BetterDisplay](https://github.com/waydabber/BetterDisplay), [MonitorControl](https://github.com/MonitorControl/MonitorControl) and [Lunar](https://lunar.fyi/).
- CGVirtualDisplay bridging header based on [Chromium's `virtual_display_mac_util.mm`](https://chromium.googlesource.com/chromium/src/+/main/ui/display/mac/test/virtual_display_mac_util.mm).
