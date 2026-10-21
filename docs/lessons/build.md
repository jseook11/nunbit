# Lessons Learned — Xcode / Build

> Updated: 2026-03-05

## Xcode / Build

- xcodegen does not generate Info.plist automatically → you must set `GENERATE_INFOPLIST_FILE: YES` in project.yml
- ScreenCaptureKit (`SCShareableContent.current`) called from a `@MainActor` context reports a non-Sendable error (even with `SWIFT_STRICT_CONCURRENCY: minimal`) → fix: `@preconcurrency import ScreenCaptureKit`
- Under Swift 6 strict concurrency, a singleton reports a Sendable error → mark the class `@unchecked Sendable` + set `SWIFT_STRICT_CONCURRENCY: minimal` in the project

## Phase 12 / Wrap-up

- After adding a new service/view file you must run `xcodegen generate` to regenerate the xcodeproj, otherwise other files that reference the new type report "cannot find in scope"
- If a Services file uses `CGDirectDisplayID`, it needs `import CoreGraphics` (`import Foundation` alone is not enough)
- `NSWorkspace.shared` needs `import AppKit` (Foundation alone is not enough)
- When an `NSObject` subclass is used as a singleton, Swift 6 reports a non-Sendable warning → mark it `@unchecked Sendable` to resolve it
- `SMAppService` (launch at login) is available on macOS 13+, and requires `import ServiceManagement`
