# Phase 20: Release Preparation

> Status: Completed | Estimate: Medium complexity

## Goal

Package FreeDisplay from a development state into a distributable, official macOS app, including an icon, code cleanup, a DMG installer, and a GitHub Release.

## Tasks

### Task 1: Code cleanup + App icon
- [x] Remove the obsolete `HiDPIPresetRow` from MenuBarView (replaced by PresetListView)
- [x] Search for and clean up other unused code/dead code
- [x] Generate the app icon with a Python PIL/Pillow script: rounded-rectangle display + the letter "F" + a blue-purple gradient
- [x] Generate all AppIcon.appiconset sizes (16/32/64/128/256/512/1024)
- [x] Create `FreeDisplay/Assets.xcassets/AppIcon.appiconset/Contents.json` + PNG files
- [x] Update project.yml to reference the AppIcon asset catalog

**Implementation hints**: Generate a 1024×1024 PNG with a Python script, then scale each size with `sips -z H W`. project.yml needs `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.

### Task 2: Launch at Login (SMAppService)
- [x] In `LaunchService.swift`, migrate the existing implementation to `SMAppService.mainApp` (macOS 13+)
- [x] Replace the old API with `register()` / `unregister()`; requires `import ServiceManagement`
- [x] Verify that the existing `fd.launchAtLogin` toggle in SettingsService is correctly wired up
- [x] First-launch prompt: if `fd.launchAtLogin` has never been set, show a one-time prompt

**Implementation hints**: `SMAppService.mainApp.register()` is a single line. Check the state with `.status == .enabled`.

### Task 3: Release build + ad-hoc signing + DMG packaging
- [x] Create a one-step `scripts/build-dmg.sh` script
- [x] Release build: `xcodebuild -scheme FreeDisplay -configuration Release build`
- [x] Ad-hoc signing: `codesign --force --deep --sign - FreeDisplay.app` (the minimum requirement without a Developer ID)
- [x] Package the DMG with `hdiutil`: FreeDisplay.app + an Applications shortcut
- [x] Document in the README that the first launch requires right-click → Open (bypassing Gatekeeper)

**Implementation hints**: `hdiutil create -volname "FreeDisplay" -srcfolder build/ -ov -format UDZO FreeDisplay.dmg`. An app signed without a Developer ID requires the user to trust it manually.

### Task 4: README + CHANGELOG + GitHub Release script
- [x] Write README.md: project overview, feature list, installation instructions, screenshot placeholders, Gatekeeper bypass instructions
- [x] Write CHANGELOG.md: summarize the main changes from Phase 0-20
- [x] Create `scripts/release.sh`: build → sign → package DMG → `gh release create`
- [x] Add a download badge to the README

**Implementation hints**: Screenshots must be captured manually with `screencapture` after running the app; use placeholders for now. `gh release create v1.0.0 --title "FreeDisplay v1.0.0" --notes-file CHANGELOG.md *.dmg`.

### Task 5: UpdateService refinements
- [x] Verify that the UpdateService update-check logic points at the GitHub Releases API
- [x] Use the placeholder URL `https://api.github.com/repos/OWNER/FreeDisplay/releases/latest` (replaced by the user when publishing)
- [x] Show a download link in the menu bar when a new version is detected
- [x] Verify that the "Check for updates on launch" toggle in the settings UI works

**Implementation hints**: The GitHub Releases API returns JSON; parse `tag_name` and compare it against the current `CFBundleShortVersionString`.

## Acceptance Criteria

```bash
# Release build
xcodebuild -scheme FreeDisplay -configuration Release build 2>&1 | tail -3

# DMG packaging
./scripts/build-dmg.sh

# Verification
# 1. Double-click the DMG to install → drag to Applications → launches normally
# 2. The app icon displays correctly in the Dock/Finder
# 3. The Launch at Login toggle works
# 4. README/CHANGELOG content is complete
```
