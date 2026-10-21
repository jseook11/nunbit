# Nunbit

> **Free & open-source alternative to [BetterDisplay](https://github.com/waydabber/BetterDisplay)** — all the core display management features, zero cost.

BetterDisplay is a great app, but its best features are locked behind a paid Pro license. Nunbit implements the most essential BetterDisplay features as a completely free, open-source macOS menu bar app.

[Download Latest Release](https://github.com/jseook11/nunbit/releases/latest) | [Report an Issue](https://github.com/jseook11/nunbit/issues)

---

## What BetterDisplay Features Does This Replace?

| BetterDisplay Feature | Nunbit | Notes |
|----------------------|:-----------:|-------|
| DDC Brightness & Contrast | ✅ | Hardware control via IOKit I2C (Intel) / IOAVService (Apple Silicon) |
| Software Brightness (Gamma) | ✅ | Per-display gamma table control with smooth transitions |
| Keyboard Brightness Keys for External Displays | ✅ | Intercepts brightness keys when cursor is on external display, shows native macOS OSD |
| Auto Brightness Sync | ✅ | Syncs external display brightness with built-in display changes |
| HiDPI Virtual Displays | ✅ | Creates HiDPI dummy displays via CGVirtualDisplay private API |
| Display Arrangement | ✅ | Position displays (external above built-in, etc.) |
| Resolution & HiDPI Switching | ✅ | Browse and switch all available display modes including HiDPI |
| ICC Color Profile Management | ✅ | Switch color profiles per display via ColorSync |
| Image Adjustment (Gamma/Temperature) | ✅ | Software contrast, color temperature, RGB channels, invert |
| Display Presets | ✅ | Save & restore full display configurations with one click |
| Virtual Display (Dummy) | ✅ | Create headless virtual displays |
| Notch Management | ✅ | Hide the MacBook notch with a black overlay |
| Launch at Login | ✅ | Via SMAppService |

### Not Included (intentionally)

- Screen streaming / PiP — rarely used, adds complexity
- EDID override — requires SIP disabled
- XDR/HDR extra brightness — requires specific hardware

---

## Screenshots

*Coming soon*

---

## Installation

### Option 1: Download DMG

1. Download `Nunbit.dmg` from [Releases](https://github.com/jseook11/nunbit/releases/latest)
2. Open the DMG and drag **Nunbit.app** to **Applications**
3. First launch: right-click → **Open** (unsigned app, one-time approval)

### Option 2: Build from Source

```bash
brew install xcodegen
git clone https://github.com/jseook11/nunbit.git
cd Nunbit
xcodegen generate
xcodebuild -scheme Nunbit -configuration Release build
```

---

## Permissions

| Permission | Why |
|------------|-----|
| **Accessibility** | Required for brightness key interception on external displays |

No internet connection required (except optional update checks via GitHub Releases API).

---

## Tech Stack

- **Swift 6** + **SwiftUI** (MenuBarExtra)
- **IOKit** — DDC/CI I2C for hardware brightness/contrast
- **CoreGraphics** — Display enumeration, resolution, arrangement
- **ColorSync** — ICC color profile management
- **CGVirtualDisplay** — Virtual display creation (private API, macOS 14+)
- **DisplayServices** — Built-in display hardware brightness read/write (private API, via dlopen)
- **CoreDisplay** — Built-in display brightness reading fallback (private API, via dlopen)
- Zero third-party dependencies

---

## Project Structure

```
Nunbit/
├── App/              # AppDelegate, app entry point
├── Models/           # DisplayInfo, DisplayMode, DisplayPreset
├── Services/         # System-level services (DDC, brightness, resolution, gamma, etc.)
└── Views/            # SwiftUI views for each feature section
```

---

## How It Works

Nunbit sits in your menu bar and talks directly to your displays:

- **External monitors**: Uses DDC/CI protocol over I2C (Intel) or IOAVService (Apple Silicon) to control hardware brightness, contrast, and other settings
- **Built-in display**: Uses the private DisplayServices API for real backlight brightness (IOKit `IODisplay*FloatParameter` fallback), with CoreGraphics gamma tables for software dimming when hardware control is unavailable
- **Brightness keys**: Installs a CGEventTap to intercept keyboard brightness keys and route them to the display under your mouse cursor
- **Auto brightness**: Polls the built-in display brightness via the DisplayServices private API (CoreDisplay/IOKit fallback) and proportionally adjusts external displays
- **HiDPI**: Creates virtual displays via CGVirtualDisplay private API, or writes display override plists for persistent HiDPI

---

## Contributing

Issues and PRs welcome. This project uses:
- `xcodegen` for project generation (edit `project.yml`, not `.xcodeproj`)
- Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal`
- MVVM architecture (View → ViewModel → Service)

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Acknowledgments

- Nunbit started as a rename of [FreeDisplay](https://github.com/huberdf/FreeDisplay) (MIT) — thanks to its contributors
- Inspired by [BetterDisplay](https://github.com/waydabber/BetterDisplay), [MonitorControl](https://github.com/MonitorControl/MonitorControl), and [Lunar](https://lunar.fyi/)
- CGVirtualDisplay bridging header based on [Chromium's virtual_display_mac_util.mm](https://chromium.googlesource.com/chromium/src/+/main/ui/display/mac/test/virtual_display_mac_util.mm)
