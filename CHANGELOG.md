# Changelog

All notable changes to Nunbit are documented here.

---

## Unreleased

### Changed
- Renamed the project from FreeDisplay to Nunbit. The bundle identifier is now `com.jseook11.nunbit`, so preferences are reset once on first launch.
- DDC brightness validates Get VCP replies and assumes a 0–100 range when a panel cannot answer reads, fixing sliders that moved without changing the panel.
- Auto Brightness can now be switched off when no built-in display is present.

### Fixed
- A Swift 6 main-actor violation that killed the app when dragging the brightness slider for an external display.
- Combined brightness now follows brightness changed elsewhere (individual sliders, System Settings, native keys, monitor buttons) instead of freezing at its first value, and it is hidden when only one physical display is connected.
- Virtual displays no longer show a brightness slider, receive brightness refreshes, or participate in Auto Brightness sync.
- The Color Profile row now shows the real active profile (e.g. "Color LCD") instead of "Unknown", and the active profile is highlighted again. macOS 26 returns `DeviceProfileURL` as an `NSURL`, which the old string-only lookup silently dropped.
- The Color Profile picker no longer lists profiles that belong to other displays. macOS stores one `<DisplayName>-<DisplayUUID>.icc` per display it has ever seen (old monitors, Sidecar sessions, virtual displays), and they all share the same description, so the list looked full of duplicates.
- Image Adjustment no longer stutters when its panel opens: it no longer re-applies the gamma table from `onAppear` (DisplayManager already restores it at launch and after configuration changes), each slider row observes only its own value via an `@Observable` model, the view no longer observes the whole `DisplayInfo`, and quantization commits once on release instead of twice.
- Image Adjustment now expands without animation and keeps the rarely used Per-Channel Gamma/Gain groups collapsed, so the common path builds five sliders instead of thirteen. It paints immediately from an in-memory cache of the saved adjustment and reconciles with the live in-memory state after the first frame only if they differ.
- Built-in display brightness now works on macOS 26: `CGDisplayIOServicePort` returns 0 and `IODisplayConnect` services no longer exist, so the old IOKit path could neither read nor write the panel. Brightness now goes through the private DisplayServices framework (`DisplayServicesGetBrightness`/`SetBrightness`), with the IOKit/CoreDisplay paths kept as fallbacks. This also fixes Auto Brightness reading a stale constant of 1.0.

---

## v1.0.0 (2026-03-05)

Initial public release — full-featured BetterDisplay alternative.

### Core Features

- **Display Detection & Menu Bar UI** (Phase 1)
  - Multi-monitor detection (built-in + external)
  - MenuBarExtra-based UI with per-display panels
  - Display identification (visual flash)

- **DDC Brightness & Contrast Control** (Phase 2)
  - IOKit I2C DDC/CI communication
  - Hardware brightness and contrast sliders for external monitors
  - Software gamma brightness for built-in displays

- **Resolution Management & HiDPI** (Phase 3)
  - Resolution list with HiDPI/native/scaled modes
  - HiDPI virtual display creation (CGVirtualDisplay)
  - Resolution slider for quick switching

- **Rotation & Arrangement** (Phase 4)
  - Display rotation: 0°/90°/180°/270°
  - Visual display arrangement editor

- **Color Management** (Phase 5)
  - ICC color profile switching per display
  - Color mode display (8-bit/10-bit, SDR/HDR)

- **Image Adjustment** (Phase 6)
  - Software contrast, gamma, color temperature
  - Per-channel RGB gain control
  - Color inversion

- **Advanced Display Management** (Phase 7)
  - Set primary display
  - Display info panel (resolution, refresh rate, vendor)

- **Screen Mirroring** (Phase 8)
  - Mirror any display to any other display
  - Mirror enable/disable toggle

- **Screen Streaming & Picture-in-Picture** (Phase 9)
  - ScreenCaptureKit-based screen capture
  - Floating PiP window with configurable size and position
  - Stream controls: flip, rotate, scale, crop, opacity, video filters

- **Virtual Display** (Phase 10)
  - Create HiDPI virtual/dummy displays
  - Useful for headless Macs or extending workspace

- **Config Protection & Auto Brightness** (Phase 11)
  - Prevent macOS from resetting display configuration
  - Time-based auto brightness scheduling

- **Notch Management** (Phase 12)
  - Notch overlay show/hide for MacBooks with notch

### Stability & Polish

- **Critical Bug Fixes** (Phase 13)
  - DDC communication reliability improvements
  - CoreGraphics API usage corrections

- **Performance Optimization** (Phase 14)
  - Async display enumeration
  - Reduced UI blocking on IOKit calls

- **UX Improvements** (Phase 15)
  - Improved slider responsiveness
  - Better error states and user feedback

- **Comprehensive Bug Fixes — 134 bugs** (Phase 16)
  - 5 rounds of systematic bug fixing across all features
  - 3 rounds of UI/UX polish
  - Unified hover effects across all views
  - Extracted reusable components: DetailRow, ExpandableRow, ProtectionRowView
  - DisplayDetailView three-group layout
  - Rotation 2×2 grid layout
  - ArrangementView interior/exterior display thumbnail distinction
  - DisplayModeList favorites pinned to top
  - ConfigProtection active protection badge

- **DDC / HiDPI / Notch Targeted Fixes** (Phase 17)
  - CGVirtualDisplay: vendorID must be non-zero
  - CGVirtualDisplay must be created on main thread
  - Bridging header property name corrections
  - One-click display presets completed

- **CG Timeout Protection + Wake Recovery** (Phase 18)
  - CoreGraphics call timeout protection
  - Sleep/wake display state recovery
  - GammaService wake notification handler
  - BrightnessService wake reapplication

### Preset System

- **Display Preset One-Click Switching** (Phase 19)
  - Save full display configuration as named preset
  - Instant restore: resolution, brightness, rotation, color profile
  - Preset management UI (create, rename, delete)

### Release

- **App Icon, DMG Packaging, Launch at Login** (Phase 20)
  - App icon: gradient blue-purple monitor with "F" lettermark
  - DMG installer with Applications shortcut
  - SMAppService-based launch at login (macOS 13+)
  - README, CHANGELOG, release automation script
  - UpdateService pointing to GitHub Releases API
