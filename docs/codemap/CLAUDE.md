# Code Map — Nunbit (Quick Reference)

> **Purpose**: quick reference for Claude's code navigation. See `file-tree.md` for the detailed file tree and `relationships.md` for the module relationship diagram.
> **Maintenance**: update descriptions and the module relationship diagram after major structural changes.

---

## Entry Files / Key Entry Points

- `CLAUDE.md`
- `docs/ROADMAP.md`
- `docs/codemap/CLAUDE.md` (this file)

Details: [file-tree.md](file-tree.md) | [relationships.md](relationships.md)

---

## Module Summary

| Module | Responsibility | Key files | Notes |
|------|------|---------|---------|
| **App** | App lifecycle, MenuBarExtra scene declaration | `NunbitApp.swift` | DisplayManager is created here and injected as an environmentObject |
| **Models** | Pure data structures, ObservableObject | `DisplayInfo.swift`, `DisplayMode.swift` | Changing a DisplayInfo property requires a global grep to sync |
| **Services** | System framework interaction, no UI | `DDCService.swift`, `DisplayManager.swift`, `BrightnessService.swift`, etc. | Most Services are @MainActor singletons |
| **Views** | SwiftUI views, pure presentation and interaction | `MenuBarView.swift`, `DisplayDetailView.swift` | Do not put business logic in Views; call Services |
| **Utilities** | System type extensions | `NSScreenExtension.swift` | Depended on from many places, avoid changing casually |

---

## High-Risk Files ⚠️

| File | Risk reason | Required when changing |
|------|---------|---------|
| `Models/DisplayInfo.swift` | 12+ @Published properties, every View and Service depends on it | grep all reference sites and update them |
| `Services/DisplayManager.swift` | @Published displays injected globally, hot-plug callbacks | After changes, verify hot-plug and multi-display enumeration |
| `Services/DDCService.swift` | IOKit I2C low-level communication, the foundation of every external display feature | Must be manually tested on a real external display |
| `Views/MenuBarView.swift` | The entry container for every feature, nests all Section entry points | After adding a Section, check the layout and scroll height |
| `Views/DisplayDetailView.swift` | The expanding container for 12 Sections, many state variables | When adding a Section, make sure @State names do not collide |

---

## Common Tasks → Which Files to Modify

| Task | Files to modify |
|------|--------------|
| Add a display property (e.g. HDR state) | `Models/DisplayInfo.swift` → grep all references → related View/Service |
| Add a DDC VCP feature (e.g. volume control) | `Services/DDCService.swift` (add the VCP constant) → create a new Service → create a new View → `Views/DisplayDetailView.swift` (add a Section) → `docs/codemap/CLAUDE.md` |
| Add a menu bar tool entry (not display-related) | `Views/MenuBarView.swift` (add the entry in the tools area) → create a new View/Service → `docs/codemap/CLAUDE.md` |
| Modify resolution switching logic | `Services/ResolutionService.swift`, `Models/DisplayMode.swift`; test the impact on `Views/ResolutionSliderView.swift` and `Views/DisplayModeListView.swift` |
| Modify brightness read/write | `Services/BrightnessService.swift`; built-in panel hardware calls go through `Services/DisplayServicesBrightness.swift`; for external displays also check `Services/DDCService.swift` |
| Modify image adjustment effects | `Services/GammaService.swift` (formula/Table calculation), `Views/ImageAdjustmentView.swift` (UI slider mapping) |
| Add a new persisted setting | `Services/SettingsService.swift` (Keys + @Published property + loadAll/persist) → related View |
| Modify notification/hot-plug handling | `Services/DisplayManager.swift` (displayReconfigCallback + refreshDisplays) |
| Modify HiDPI Override generation | `Services/HiDPIService.swift` (generateScaledModes + plist path) |
| Modify the color picker/color history | `Views/SystemColorView.swift` (SystemColorViewModel), `Services/SettingsService.swift` (colorPickerHistory) |
| Modify virtual display logic | `Services/VirtualDisplayService.swift`, `Nunbit-Bridging-Header.h` (private API declarations) |

---

## Pitfalls

- **DisplayInfo property coupling**: change `DisplayInfo` → grep all reference sites and update them, otherwise the code may compile but behave incorrectly
- **project.yml**: after changing it you must run `xcodegen generate` to regenerate the xcodeproj
- **New source files**: every `.swift` file under `Nunbit/` is included automatically by xcodegen; no need to edit `project.yml`
- **Swift 6 concurrency**: the project sets `SWIFT_STRICT_CONCURRENCY: minimal`; handle concurrency errors with `@MainActor` or `@unchecked Sendable`
- **No Sandbox**: App Sandbox is disabled in entitlements, so direct access to IOKit / /Library/Displays and similar is available
- **Bridging Header private APIs**: the CGVirtualDisplay / IOAVService declarations in `Nunbit-Bridging-Header.h` are verified against the Chromium source; re-check property names before modifying them
- **HiDPIService permissions**: writing to `/Library/Displays/` requires administrator privileges; when there are none, an error string is returned for the UI to display
- **CGHelpers.runWithTimeout**: WindowServer IPC may block the main thread, so every CG configuration transaction must go through this utility and execute on a background thread under timeout protection
