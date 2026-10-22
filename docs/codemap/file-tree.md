# File Tree — Nunbit (Annotated)

> Complete annotated directory structure. See [CLAUDE.md](CLAUDE.md) for the quick reference and [relationships.md](relationships.md) for module relationships.

---

```
Nunbit/
├── docs/                           # Project documentation directory
│   ├── roadmap/                    # Phase planning documents (planner output, do not hand-edit the structure)
│   │   ├── phase-18.md             # Phase 18: stability hardening + timeouts + post-wake HiDPI restore
│   │   ├── phase-19.md             # Phase 19: display preset system
│   │   ├── phase-20.md             # Phase 20: release preparation (icon, DMG, GitHub Release)
│   │   ├── phase-21.md             # Phase 21: feature simplification
│   │   └── phase-22.md             # Phase 22: auto brightness rewrite + HiDPI plist override
│   ├── lessons/                    # Pitfalls and lessons learned
│   │   ├── CLAUDE.md               # Lessons index (read this first)
│   │   ├── build.md                # Build/xcodegen lessons
│   │   ├── coregraphics.md         # CoreGraphics configuration/transaction lessons
│   │   ├── iokit.md                # IOKit/DDC lessons
│   │   ├── services.md             # Service-layer design lessons
│   │   └── swiftui.md              # SwiftUI component/state lessons
│   ├── codemap/                    # Code navigation map (this directory)
│   │   ├── CLAUDE.md               # Quick reference index (module summary, high-risk files, task table)
│   │   ├── file-tree.md            # Complete annotated directory structure (this file)
│   │   └── relationships.md        # Module relationship diagram + service internal dependencies + data flow
│   ├── BLOCKING.md                 # Blocking issue tracking (must read before starting work)
│   ├── PERSONAL-FORK.md            # Personal fork notes (headless session, lecture mode, etc.)
│   └── ROADMAP.md                  # Overall progress tracking (progress is tracked by the [x] markers here)
├── Nunbit/                    # Swift source directory (xcodegen includes every .swift automatically)
│   ├── App/                        # App entry point, SwiftUI App lifecycle
│   │   ├── AppDelegate.swift       # NSApplicationDelegate, ensures menu bar only; changes affect App lifecycle hooks
│   │   └── NunbitApp.swift    # @main entry, creates DisplayManager and mounts MenuBarView; changes affect the whole App init chain
│   ├── Models/                     # Data model layer (pure data, no side effects)
│   │   ├── DisplayInfo.swift       # ⚠️ Core display model, 12+ @Published properties; every View/Service depends on this class, adding or removing properties requires a global grep sync
│   │   ├── DisplayMode.swift       # Value type for a single display mode (resolution + refresh rate + HiDPI flag); enumeration changes affect resolution switching and the mode list
│   │   └── DisplayPreset.swift     # Display configuration preset model: DisplayPreset (preset) + DisplayPresetEntry (single display snapshot); Codable, persisted by PresetService
│   ├── Services/                   # Business logic layer, interacts with system frameworks directly
│   │   ├── ArrangementService.swift        # Reads/writes display positions via CGDisplayConfiguration; apply(origins:) commits all coordinates in a single transaction, setAsMainDisplay moves the target to (0,0) by shifting the whole layout (no longer relies on a cached DisplayInfo list); changes affect drag arrangement and main display switching
│   │   ├── AutoBrightnessService.swift     # Polls the built-in panel brightness every 2 s (DisplayServices first, CoreDisplay/IOKit fallback) and mirrors it to external displays with a sensitivity multiplier; polling stops when there is no active built-in source or physical external target and resumes on display changes/wake; changes affect auto brightness accuracy and battery consumption
│   │   ├── BrightnessHUDService.swift      # Native macOS brightness OSD via the private OSDUIHelper XPC service; produces the exact brightness indicator macOS shows natively
│   │   ├── BrightnessKeyService.swift      # CGEventTap that intercepts the macOS brightness keys and routes them to the display under the mouse cursor; external display events are consumed and adjusted via BrightnessService, built-in display events pass through
│   │   ├── BrightnessService.swift         # Unified brightness interface: built-in displays use DisplayServices (IOKit fallback), external displays use DDC VCP 0x10; changes affect every brightness read/write path
│   │   ├── CGHelpers.swift                 # Shared CG blocking-call utility: CGHelpers.runWithTimeout(seconds:fallback:operation:) runs blocking WindowServer IPC on a background thread under timeout protection; used by ArrangementService, MirrorService, ResolutionService, VirtualDisplayService
│   │   ├── ColorProfileService.swift       # ICC Profile enumeration (scans 3 system directories) and switching (ColorSync API); changes affect the color profile list and switching
│   │   ├── DDCService.swift                # ⚠️ IOKit I2C DDC/CI communication core: IOFramebuffer lookup, VCP read/write, 5-second success cache, 20-second negative cache for failed reads, 3 retries; the low-level dependency of almost every external display feature, change with extreme care
│   │   ├── DisplayServicesBrightness.swift  # Private DisplayServices framework (dlopen/dlsym) wrapper: built-in panel brightness get/set/canChange. Primary path on macOS 26, where CGDisplayIOServicePort returns 0 and IODisplayConnect no longer exists; used by BrightnessService and AutoBrightnessService
│   │   ├── DisplayManager.swift            # ⚠️ Display enumeration (CGGetOnlineDisplayList) + CGDisplay hot-plug callback + arrangeExternalAboveBuiltin() automatic external display positioning; posts .nunbitDisplaysDidChange after the display set is replaced; @Published displays is injected globally, changes affect the entire display list data flow
│   │   ├── GammaService.swift              # Software gamma adjustment: CGSetDisplayTransferByFormula/Table, supports contrast/gain/color temperature/quantization/inversion; the only entry point for all gamma/software brightness writes; changes affect image adjustment effects
│   │   ├── HeadlessSessionService.swift    # Personal fork: headless session. Create/activate a virtual display → set it as the main display → hold a sleep-prevention assertion; listens for display changes and re-ensures the virtual display is main after a physical display power cycle; on stop, restores the original main display and destroys the virtual display created by this session
│   │   ├── HiDPIService.swift              # Writes /Library/Displays/...plist to inject HiDPI scaled modes, requires administrator privileges; changes affect HiDPI override generation
│   │   ├── LaunchService.swift             # SMAppService manage launch at login (macOS 13+); changes only affect the Launch at Login feature
│   │   ├── MirrorService.swift             # Enable/stop CGDisplayConfiguration hardware-level screen mirroring; enableMirror/disableMirror are now async, with CG transactions executed inside CGHelpers.runWithTimeout; changes affect mirroring
│   │   ├── NotchOverlayManager.swift       # Creates a black overlay NSWindow over the built-in display's notch area (screenSaver level); changes affect the notch overlay's appearance and layering
│   │   ├── ResolutionService.swift         # Switches display modes via CGConfigureDisplayWithDisplayMode; applyModeSync is now async, with the whole CG transaction executed inside CGHelpers.runWithTimeout; resolvedTargetDisplayID() falls back to VirtualDisplayService during mirror detection; changes affect resolution switch success rate
│   │   ├── SettingsService.swift           # UserDefaults + JSON file persistence of global and per-display settings; mind key naming (must use the fd. prefix) and backward compatibility
│   │   ├── SleepAssertionService.swift     # Personal fork: IOPM sleep-prevention assertions (equivalent to caffeinate -di), with reference counting for the lecture/headlessSession owners; the kernel releases them automatically on process exit, so no permanent assertion is left behind
│   │   ├── UpdateService.swift             # Checks for new versions via the GitHub Releases API, semantic version comparison; changes affect update check logic
│   │   ├── VirtualDisplayService.swift     # Virtual display creation/destruction: CGVirtualDisplay private API; width/height are logical sizes, maxPixels is 2× backing when HiDPI; polls displayID/online after apply; derives a stable product/serial from the config UUID; supports activate/deactivate, wake rebuild, autoCreate dedupe; changes affect virtual displays and the headless session
│   │   └── PresetService.swift             # Preset management: save/load/apply display configuration presets; reads current display state through DisplayManagerAccessor; presets.json is stored in ~/Library/Application Support/Nunbit/
│   ├── Utilities/                  # Utility extensions
│   │   └── NSScreenExtension.swift         # NSScreen extension: find an NSScreen by CGDirectDisplayID, get the displayID; depended on by NotchView, NotchOverlayManager
│   ├── Nunbit-Bridging-Header.h       # Private API declarations: CGVirtualDisplay (macOS 14+) and IOAVService (Apple Silicon DDC); property names verified against the Chromium source (maxPixelsWide/maxPixelsHigh, not maxPixelSize)
│   └── Views/                      # SwiftUI view layer
│       ├── ArrangementView.swift           # Multi-display drag arrangement canvas (internal/external thumbnails distinguished) + set-as-main-display button; depends on ArrangementService
│       ├── AutoBrightnessView.swift        # Auto brightness toggle + sensitivity slider + ambient lux display; depends on AutoBrightnessService
│       ├── BrightnessSliderView.swift      # Single-display brightness slider (200ms debounce) + combined global brightness control; follow-up polls are gated by both task cancellation and onDisappear; depends on BrightnessService + DDCService
│       ├── ColorProfileView.swift          # ICC Profile list (recommended/all grouping) and switching; depends on ColorProfileService
│       ├── DisplayDetailView.swift         # ⚠️ Per-display expansion panel, the container for collapsible Sections (three groups); adding/removing a Section requires editing this file and syncing MenuBarView
│       ├── DisplayModeListView.swift       # Resolution mode list (HiDPI/native/other grouping), favorites pinned with a star, click to switch; depends on ResolutionService
│       ├── ImageAdjustmentView.swift       # Gamma/contrast/gain/color temperature/quantization + collapsed Per-Channel Gamma/Gain groups; renders from cached saved state and reconciles with the live adjustment; uses the lightweight CompactSlider instead of the AppKit Slider to keep the MenuBarExtra first paint cheap; depends on GammaService
│       ├── MainDisplayView.swift           # "Set as Main Display" row, shows a status label when it is already the main display; depends on ArrangementService
│       ├── MenuBarView.swift               # ⚠️ Menu bar main view: display list + expand/collapse + tools area + settings area + PresetListView; the entry container for every feature, changes affect the global layout
│       ├── NotchView.swift                 # Notch info display + overlay toggle (shown only on built-in displays that have a notch); depends on NotchOverlayManager
│       ├── PresetListView.swift            # Preset section: segmented toggle for built-in presets, rows for user-created presets, plus the save-preset button; depends on PresetService
│       ├── ResolutionSliderView.swift      # Horizontal resolution drag slider (applies on release); depends on ResolutionService, reads DisplayInfo.availableModes
│       ├── SystemColorView.swift           # System color picker (NSColorSampler) + HEX/RGB/HSB display + history; depends on SettingsService for color history persistence
│       ├── HiDPIView.swift                 # HiDPI Override status row (plist approach) + write/revert buttons; depends on HiDPIService
│       ├── HeadlessSessionView.swift       # Personal fork: headless session UI (select virtual display + start/stop + status/errors); depends on HeadlessSessionService
│       ├── LectureModeView.swift           # Personal fork: lecture mode toggle (sleep prevention only, no virtual display, compatible with FairPlay/DRM); depends on SleepAssertionService
│       ├── VirtualDisplayView.swift        # Virtual display configuration list + creation form (preset resolutions) + one-click HiDPI preset + enable/disable buttons; depends on VirtualDisplayService
│       └── SavePresetView.swift            # Saves the current display state as a preset; inline form (name + icon picker); calls PresetService.captureCurrentState + addPreset
├── scripts/                        # Build and release scripts
│   ├── build-dmg.sh                # Release build + DMG packaging
│   ├── build-local.sh              # Xcode-free build (swiftc + hand-assembled bundle + ad-hoc signing); flags: --debug, --install, --run
│   ├── generate-icon.py            # Icon generation/processing script
│   └── release.sh                  # Build → package DMG → gh release create
├── Nunbit.xcodeproj/          # Xcode project file (generated by xcodegen, do not edit by hand)
├── .gitignore                      # Git ignore rules
├── AGENTS.md                       # Harness configuration for AI agents (read before any change)
├── build.sh                        # Quick build script
├── CHANGELOG.md                    # Release changelog
├── CLAUDE.md                       # Claude context entry point (project rules, decision conventions)
├── ExportOptions.plist             # Release signing configuration
├── LICENSE                         # License
├── project.yml                     # xcodegen configuration, must re-run xcodegen generate after changes
└── README.md                       # Project readme
```
