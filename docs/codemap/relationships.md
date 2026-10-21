# Module Relationships — FreeDisplay

> Module relationship diagram, Services internal dependencies, data flow. See [CLAUDE.md](CLAUDE.md) for the quick reference and [file-tree.md](file-tree.md) for the file tree.

---

## Module Relationship Diagram

```
App (FreeDisplayApp)
  └── @StateObject DisplayManager
        └── @Published [DisplayInfo]
              └── MenuBarView (@EnvironmentObject DisplayManager)
                    ├── DisplayRowView
                    │     └── DisplayDetailView  ← 12 Sections (three groups)
                    │           ├── BrightnessSliderView     → BrightnessService → DDCService
                    │           ├── ResolutionSliderView     → ResolutionService
                    │           ├── DisplayModeListView      → ResolutionService
                    │           ├── ColorProfileView         → ColorProfileService
                    │           ├── ImageAdjustmentView      → GammaService
                    │           ├── MainDisplayView          → ArrangementService
                    │           ├── NotchView                → NotchOverlayManager
                    │           └── HiDPIRowView             → HiDPIService (plist override)
                    ├── ArrangementView          → ArrangementService
                    ├── VirtualDisplayView       → VirtualDisplayService
                    ├── AutoBrightnessView       → AutoBrightnessService → BrightnessService
                    ├── LectureModeView          → SleepAssertionService (system sleep assertion)
                    ├── HeadlessSessionView      → HeadlessSessionService
                    │                                → VirtualDisplayService / ArrangementService / SleepAssertionService
                    ├── SystemColorMenuEntry     → SystemColorView → SettingsService
                    └── SettingsView             → SettingsService, LaunchService
```

---

## Services Internal Dependencies

```
BrightnessService ──────────→ DDCService (external display DDC brightness read/write)
AutoBrightnessService ──────→ BrightnessService (called after mapping lux→brightness)
DisplayManager ─────────────→ BrightnessService (async brightness init on refresh)
               ─────────────→ ArrangementService (setAsMainDisplay)
               ─────────────→ arrangeExternalAboveBuiltin() (auto positioning after hot-plug)

CGHelpers (shared utility) ─→ used by the following Services (WindowServer IPC timeout protection):
  ArrangementService (setPosition/setAsMainDisplay CG transaction)
  MirrorService (enableMirror/disableMirror CG transaction)
  ResolutionService (applyModeSync CG transaction)
  VirtualDisplayService (CGVirtualDisplay apply transaction)

GammaService (gamma owner) ─→ the only Service that writes CGSetDisplayTransferByFormula/Table
  BrightnessService ─────────→ GammaService (software brightness is written through GammaService, never directly to CG)
  ❌ The View layer must not call CGSetDisplayTransferByFormula/Table directly
  ❌ Must not use CGDisplayRestoreColorSyncSettings() (global); use GammaService.resetSingleDisplay(displayID) instead

ResolutionService ──────────→ VirtualDisplayService.virtualDisplayID(for:) (mirror detection fallback)

HeadlessSessionService ─────→ VirtualDisplayService (create/activate the virtual display)
                        ─────→ ArrangementService.setAsMainDisplay (shift the layout in a single transaction)
                        ─────→ SleepAssertionService (system + display sleep prevention)

SleepAssertionService ──────→ IOPMAssertionCreateWithName (the kernel releases it automatically on process exit)
  lecture owner       ─────→ PreventUserIdleSystemSleep only
  headlessSession owner ───→ PreventUserIdleSystemSleep + PreventUserIdleDisplaySleep
```

---

## Data Flow

```
Unidirectional data flow (reactive):
  CGDisplayAPI / IOKit → Services → DisplayInfo (@Published) → Views (reactive SwiftUI)
  User interaction    → Views   → Services → Hardware

Sleep/wake data flow:
  NSWorkspace.didWakeNotification → AppDelegate
    → GammaService.reapplyIfNeeded()
    → BrightnessService.reapplySoftwareBrightnessIfNeeded()

Hot-plug data flow:
  CGDisplayRegisterReconfigurationCallback → DisplayManager.displayReconfigCallback
    → refreshDisplays()
    → arrangeExternalAboveBuiltin()
    → @Published displays update → global View re-render

Virtual display data flow:
  VirtualDisplayView → VirtualDisplayService.create(config:)
    → CGVirtualDisplay(descriptor:) [main thread, maxPixels = HiDPI ? logical×2 : logical]
    → apply(settings) [background, CGHelpers.runWithTimeout]
    → poll displayID + CGDisplayIsOnline (up to 5 seconds)
    → activeDisplayObjects holds a strong reference; destroy = ARC release
    → headless session: setAsMainDisplay → SleepAssertionService.acquire(.headlessSession)
```
