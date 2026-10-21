# Phase 19: Display Preset System

> Status: Completed | Estimate: Medium complexity

## Goal

Expand the one-click HiDPI feature into a general display preset system, where users can save the current display state as a preset and switch between configurations with one click.

## Tasks

### Task 1: Preset data model
- [x] Create `Models/DisplayPreset.swift` and define the preset struct:
  - `id: UUID`, `name: String`, `icon: String` (SF Symbol name)
  - `displays: [DisplayPresetEntry]`, each entry containing:
    - `displayUUID: String` (matches a physical display)
    - `width: Int`, `height: Int`, `isHiDPI: Bool` (target resolution)
    - `brightness: Double?` (optional brightness)
    - `arrangement: CGPoint?` (optional arrangement position)
    - `enableHiDPIVirtual: Bool` (whether to enable the HiDPI virtual display)
- [x] Create `Services/PresetService.swift`: load/save/apply presets
- [x] Store presets in `~/Library/Application Support/FreeDisplay/presets.json`

**Implementation hints**: Match displays with `display.displayUUID` (the stable UUID generation logic already exists). When applying a preset, skip any entry whose display is offline.

### Task 2: Built-in default presets
- [x] "HiDPI Mode": reuse the current HiDPIPresetRow logic (enableHiDPIVirtual + 1920×1080 + arrangement)
- [x] "Native Mode": disable the HiDPI virtual display + restore the display's native resolution + arrangement
- [x] Built-in presets cannot be deleted and are marked with `isBuiltin: true`

**Implementation hints**: Move the turnOn/turnOff logic of HiDPIPresetRow into PresetService.applyPreset(), and change HiDPIPresetRow to call PresetService.

### Task 3: Save the current state as a preset
- [x] Add a "Save as Preset" button to the menu bar (below the preset list)
- [x] On click, show an inline form: enter a name, choose an icon
- [x] Automatically capture the resolution, HiDPI state, brightness, and arrangement position of all current displays
- [x] Save to presets.json

**Implementation hints**: Follow the inline form pattern of CreateVirtualDisplayForm. Use a Picker plus a few predefined SF Symbols for icon selection.

### Task 4: Preset list and one-click switching
- [x] Show the preset list in MenuBarView (replace the HiDPIPresetRow position with a preset section)
- [x] Each preset shows: icon + name + whether it currently matches (green "Current" badge)
- [x] Click a preset → apply it (show a loading spinner)
- [x] Long press/right click → delete (non-built-in presets only)

**Implementation hints**: Preset matching: iterate over every DisplayPresetEntry and check whether the current resolution and HiDPI state match. If everything matches, mark it as "Current".

## Acceptance Criteria

```bash
# Build passes
xcodebuild -scheme FreeDisplay -configuration Debug build 2>&1 | tail -3

# Manual tests
# 1. Enable HiDPI → save as preset "Work Mode" → turn HiDPI off → click "Work Mode" → HiDPI is restored
# 2. Switch to 1280×720 → save as preset "Low Resolution" → switch between the two presets
# 3. The built-in "HiDPI Mode" and "Native Mode" cannot be deleted
```
