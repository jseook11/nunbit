# Phase 21: Feature Trimming — Removing Unused Features

> Status: Completed | Estimate: Medium complexity

## Goal

Remove impractical features (rotation, streaming/PiP, color mode inversion, mirror UI), slim down the codebase, and reduce maintenance burden.

## Tasks

### Task 1: Remove the rotation feature
- [x] Delete `Services/RotationService.swift`
- [x] Delete `Views/RotationView.swift`
- [x] `DisplayDetailView.swift`: remove the `showRotation` state, the rotation DetailRow, the RotationView embed, and loadExpanded/saveExpanded("rotation")
- [x] `DisplayInfo.swift`: remove the `rotation: Double` property (confirmed via grep that nothing else references it)
- [x] `ConfigProtectionService.swift`: remove the `RotationService.shared.setRotation` calls (about 2 places), the `ProtectedItems.rotation` field, and the `DisplayConfig.rotation` field
- [x] `ConfigProtectionView.swift`: remove the rotation protection toggle

**Implementation hints**: First grep for `RotationService\|RotationView\|\.rotation` to find every reference, then clean them up one by one.

### Task 2: Remove streaming + PiP + video filters
- [x] Delete `Services/ScreenCaptureService.swift`
- [x] Delete `ViewModels/StreamViewModel.swift`
- [x] Delete `Views/StreamControlView.swift`
- [x] Delete `Views/StreamWindow.swift`
- [x] Delete `Views/PiPControlView.swift`
- [x] Delete `Views/PiPWindow.swift`
- [x] Delete `Views/VideoFilterWindow.swift`
- [x] `DisplayDetailView.swift`: remove the `showStream` and `showPiP` states + their DetailRows + embeds
- [x] `MenuBarView.swift`: remove VideoFilterMenuEntry and SystemColorMenuEntry (if present)

**Implementation hints**: These 7 files are isolated islands; after deleting them, grep for `ScreenCaptureService\|StreamViewModel\|StreamControlView\|PiPControlView\|PiPWindow\|VideoFilter` to confirm no references remain.

### Task 3: Remove color modes (inversion/grayscale) and the mirror UI
- [x] Delete `Views/ColorModeView.swift`
- [x] Delete `Views/MirrorView.swift` (keep `Services/MirrorService.swift`; HiDPI depends on it)
- [x] `DisplayDetailView.swift`: remove the `showColorMode` and `showMirror` states + their DetailRows + embeds
- [x] `DisplayDetailView.swift`: clean up the `colorModeDesc` related state (keep `colorSpaceName`; ColorProfile needs it)

**Implementation hints**: MirrorService.swift must NOT be deleted! The HiDPI feature in VirtualDisplayService depends on MirrorService.enableMirror/disableMirror.

### Task 4: Build verification + cleanup
- [x] `xcodegen generate && xcodebuild -scheme Nunbit -configuration Debug build`
- [x] Update the code map under `docs/codemap/` to remove records of deleted files
- [x] Update `README.md`: remove the deleted features from the feature list
- [x] Update `CHANGELOG.md`: add a v1.1.0 entry documenting the feature trimming

## Acceptance Criteria

```bash
# Build passes
xcodebuild -scheme Nunbit -configuration Debug build 2>&1 | tail -3

# Confirm the files are deleted
ls Nunbit/Services/RotationService.swift 2>&1  # should not exist
ls Nunbit/Views/RotationView.swift 2>&1         # should not exist
ls Nunbit/Views/StreamControlView.swift 2>&1    # should not exist

# Confirm no references remain
grep -r "RotationService\|RotationView\|StreamControlView\|PiPControlView\|ColorModeView\|MirrorView" Nunbit/ --include="*.swift" | grep -v "^Binary"
# should return nothing
```
