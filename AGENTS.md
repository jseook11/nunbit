# AGENTS.md — Nunbit Project Harness Configuration

> This file defines the harness rules for AI agents working on this project.
> AI agents MUST read this file before making any changes.
> For deeper context, read CLAUDE.md first.

## Project Overview

- **Name**: Nunbit
- **Language**: Swift 6.0 (concurrency checking set to minimal)
- **Framework**: SwiftUI (MenuBarExtra) + AppKit
- **Package Manager**: None (zero third-party dependencies, all system frameworks)
- **Build Tool**: XcodeGen (`project.yml`) + xcodebuild
- **Minimum OS**: macOS 14.0
- **Architecture**: MVVM — View → ViewModel → Service

## Architecture Rules

### Layer Separation

```
Views/          → UI presentation, reads ViewModel only, or reads Service directly (simple cases)
ViewModels/     → State management, bridges View and Service
Services/       → Business logic, interacts with system frameworks (IOKit/CoreGraphics/DDC)
Models/         → Pure data structures (DisplayInfo, DisplayMode, DisplayPreset)
```

- The View layer must not call CoreGraphics / IOKit / CGSet* family APIs directly
- Writing a gamma table must go through GammaService; never bypass it
- BrightnessService (software brightness) writes through GammaService and does not call CGSetDisplayTransferByTable directly

### Module Boundaries

| Directory | Responsibility |
|------|------|
| `Nunbit/Services/` | All system-level operations (DDC, brightness, resolution, HiDPI, arrangement, etc.) |
| `Nunbit/Views/` | SwiftUI views, file name format: `XxxView.swift` or `XxxRow.swift` |
| `Nunbit/ViewModels/` | State management, 1:1 with a View or shared across multiple Views |
| `Nunbit/Models/` | Data structures, no side effects |
| `Nunbit/Utilities/` | General-purpose helper functions |
| `Nunbit/Resources/` | Static resources |
| `docs/` | Project documentation (do not change the structure) |
| `scripts/` | Build and release scripts |

### Protected Files

The following files require a clear explanation of the reason before modification:

- `Nunbit/Nunbit.entitlements` — permission declarations, changes affect signing and App Sandbox
- `project.yml` — XcodeGen configuration, `xcodegen generate` must be re-run after changes
- `ExportOptions.plist` — release signing configuration
- `docs/roadmap/` — planning documents, only update `[x]` progress markers, do not change the structure

## Coding Standards

### Style Guide

- Swift 6.0 syntax; do not fall back to compatibility-era idioms
- Prefer SwiftUI views; use AppKit only when necessary
- Private frameworks (CoreDisplay, etc.) must be loaded at runtime with `dlopen` + `dlsym`; `@_silgen_name` is forbidden

### Naming Conventions

- Service classes: `XxxService.swift`, singletons use `static let shared`
- View files: `XxxView.swift`
- Reusable row components: `XxxRow` (struct, supports `@State`)
- UserDefaults keys: must carry the `fd.` prefix (e.g. `fd.launchAtLogin`)
- Bare keys are forbidden (e.g. `"launchAtLogin"`)

### SwiftUI Component Rules

- Row components that need local state (`isHovered`, `isLoading`) → must be a standalone `struct`
- Do not carry components with `@State` inside a `@ViewBuilder` function

### Concurrency Rules

- Swift 6 concurrency errors → prefer `@MainActor` or `@unchecked Sendable`
- Long-lived C callbacks (e.g. CGDisplayRegisterReconfigurationCallback) → use `Unmanaged.passRetained(self)`, `release()` on deregistration
- `passUnretained` is forbidden (dangling pointer risk)
- Only make genuinely slow operations async (filesystem scans, network requests); keep microsecond-level IOKit calls synchronous

## Testing Requirements

### Verification Commands

```bash
# Compile check (Debug) — must run after every change
xcodebuild -scheme Nunbit -configuration Debug build 2>&1 | tail -20

# Coupling check (when interfaces/models change)
grep -r "DisplayInfo\|DisplayManager\|DDCService" Nunbit/ --include="*.swift" | grep -v "^Binary"

# Regenerate xcodeproj (must run when project.yml changes)
xcodegen generate

# Release build + DMG packaging
./build.sh
```

### Test Coverage

- This project has no automated test suite (strongly hardware-dependent, manual testing is the norm)
- New DDC features must be manually verified on a real external display
- New HiDPI features require reconnecting the display to verify they take effect

## Git Discipline

### Branch Naming

- `feature/xxx` — new feature
- `fix/xxx` — bug fix
- `refactor/xxx` — refactor
- `phase-N/xxx` — changes corresponding to a ROADMAP Phase

### Commit Message Format

Follow Conventional Commits:

```
feat: add auto brightness adjustment
fix: fix HiDPI plist write permission issue
refactor: extract GammaService to centralize transfer function management
```

### Co-Author Line

```
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

## Forbidden Operations

- Do NOT: call `CGSetDisplayTransferByTable` / `CGSetDisplayTransferByFormula` directly (bypasses GammaService)
- Do NOT: call `CGDisplayRestoreColorSyncSettings()` (global reset) — use `GammaService.resetSingleDisplay(displayID)`
- Do NOT: use `CGConfigureDisplayMirrorOfDisplay` to implement HiDPI (Apple Silicon triggers hardware mirroring + mouse stutter)
- Do NOT: reference private framework symbols with `@_silgen_name` (undefined symbol at link time)
- Do NOT: match IOKit services using `CGDisplayVendorNumber/ModelNumber` (unreliable on some displays)
- Do NOT: set `DisplayProductName` in a plist (overrides the system display name)
- Do NOT: modify the `docs/roadmap/` directory structure
- Do NOT: add third-party dependencies (project policy: zero dependencies)
- Do NOT: access low-level system framework APIs directly in the View layer

## Agent-Specific Notes

### Kickoff Checklist

1. Read `docs/BLOCKING.md` first; resolve any P0/P1 issues before anything else
2. Read `docs/ROADMAP.md` to understand the current Phase
3. Read `docs/codemap/CLAUDE.md` → `docs/codemap/file-tree.md` to locate the relevant files

### Post-Change Coupling Checks

- Changed a `DisplayInfo` property → grep all reference sites and update them
- Changed `project.yml` → must run `xcodegen generate`
- Added a Service/View file → update `docs/codemap/file-tree.md`
- Completed a Phase task → mark `[x]` in both `docs/roadmap/phase-N.md` and `docs/ROADMAP.md`
- Hit a pitfall → write it to `docs/lessons/{topic}.md` and update the index
- Sleep/wake related changes → confirm the Service responds to `NSWorkspace.didWakeNotification`

### Situations That Require Stopping to Ask the User

- Needing to use a new private API (CoreDisplay, etc.)
- Needing SIP disabled or special system permissions
- Architecture direction change (MVVM to another pattern)

### Core Framework Quick Reference

| Framework | Purpose |
|------|------|
| CoreGraphics | Display enumeration, resolution, arrangement |
| IOKit | DDC/CI I2C communication, brightness/contrast |
| ColorSync | ICC Profile management |
| CGVirtualDisplay (private) | Virtual display, vendorID must be non-zero, call on the main thread |
| DisplayServices (dlsym) | Built-in display brightness read/write (primary on macOS 26) |
| CoreDisplay (dlsym) | Built-in display brightness reading (fallback) |

<!-- Generated by Harness Engineering system on 2026-03-12. Review and customize. -->
