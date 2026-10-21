# Roadmap — FreeDisplay

> Created: 2026-03-02 | Goal: a free macOS display management menu bar app that fully replaces BetterDisplay
> **Detailed implementation hints are in**: `docs/roadmap/phase-N.md`

## Completed Phases (0-17)

- Phase 0: Project init ✅
- Phase 1: Display detection and menu UI ✅
- Phase 2: Brightness control (DDC + built-in) ✅
- Phase 3: Resolution management and HiDPI ✅
- Phase 4: Screen rotation and display arrangement ✅
- Phase 5: Color management ✅
- Phase 6: Image adjustment ✅
- Phase 7: Advanced display management ✅
- Phase 8: Screen mirroring ✅
- Phase 9: Screen streaming and picture-in-picture ✅
- Phase 10: Virtual display ✅
- Phase 11: Config protection and auto brightness ✅
- Phase 12: Wrap-up and release ✅
- Phase 13: Critical bug fixes ✅
- Phase 14: Performance optimization (eliminating stutter) ✅
- Phase 15: Interaction polish ✅
- Phase 16: Comprehensive bug fixes ✅
- Phase 17: Core feature specific fixes — DDC/HiDPI/notch ✅

## Phase 18: Stability hardening ✅
> Details: `docs/roadmap/phase-18.md`

### Task 1: Unify timeout protection for blocking CG calls
- [x] Extract VirtualDisplayService's `runWithTimeout` into a shared utility function
- [x] MirrorService: add timeout protection to `enableMirror`/`disableMirror`
- [x] ArrangementService: add timeout protection to `setPosition`
- [x] ResolutionService: add a 10-second timeout to `applyModeSync`

### Task 2: Automatic re-arrangement on display configuration changes
- [x] Register `CGDisplayRegisterReconfigurationCallback`
- [x] Call `arrangeExternalAboveBuiltin()` 500ms after the configuration change completes
- [x] Debounce mechanism (only the last of multiple callbacks within 500ms executes)

### Task 3: Automatically restore HiDPI after sleep/wake
- [x] On wake, check the active HiDPI session and recreate it if lost
- [x] Restore sequence: create → apply settings → sleep 500ms → mirror → setDisplayMode → arrange
- [x] Persist HiDPI state to UserDefaults (`fd.hiDPI.activePhysicalIDs`)

### Task 4: Error recovery and user feedback
- [x] Show a menu bar status hint when a CG call times out
- [x] Prompt the user to manually re-enable HiDPI when restoration fails
- [x] Automatically disable HiDPI and notify after 3 consecutive failures

## Phase 19: Display preset system ✅
> Details: `docs/roadmap/phase-19.md`

### Task 1: Preset data model
- [x] Create `Models/DisplayPreset.swift`
- [x] Create `Services/PresetService.swift`: load/save/apply presets
- [x] Presets are stored in `~/Library/Application Support/FreeDisplay/presets.json`

### Task 2: Built-in default presets
- [x] "HiDPI Mode": enableHiDPIVirtual + 1920×1080 + arrangement
- [x] "Native Mode": disable the HiDPI virtual display + restore the native resolution + arrangement
- [x] Built-in presets cannot be deleted (`isBuiltin: true`)

### Task 3: Save the current state as a preset
- [x] Add a "Save as Preset" button to the menu bar
- [x] Inline form: enter a name, choose an icon
- [x] Automatically capture the current state of all displays and save it

### Task 4: Preset list and one-click switching
- [x] Show the preset list in MenuBarView (replacing the HiDPIPresetRow position)
- [x] Each preset shows an icon + name + a badge for the current match
- [x] Click a preset → apply (loading spinner)
- [x] Long press/right click → delete (non-built-in presets)

## Phase 20: Release preparation ✅
> Details: `docs/roadmap/phase-20.md`

### Task 1: App icon
- [x] Design the display icon and generate every size for AppIcon.appiconset
- [x] Update project.yml to reference AppIcon

### Task 2: Launch at Login optimization
- [x] Confirm the use of `SMAppService.mainApp` (macOS 13+)
- [x] Prompt the user on first launch whether to launch at login

### Task 3: DMG packaging
- [x] Create the `scripts/build-dmg.sh` script
- [x] Release build + DMG packaging (FreeDisplay.app + Applications shortcut)

### Task 4: GitHub Release
- [x] Add feature screenshots to README.md
- [x] Add CHANGELOG.md
- [x] `scripts/release.sh`: build → package DMG → gh release create

### Task 5: UpdateService polish
- [x] Confirm the update check logic points at the GitHub Releases API
- [x] Show a download link when a new version is detected
- [x] Confirm the "Check for updates on launch" toggle works
