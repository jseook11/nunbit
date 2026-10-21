# Blocking Issues — FreeDisplay

> Updated: 2026-03-02 | **Must read before starting work; unresolved P0/P1 issues must be handled first**

## Scheduling Rules

1. Finish reading this file → if there are P0/P1 issues → **resolve them one by one from highest to lowest priority, and only work on the ROADMAP once all are cleared**
2. If there are only P2 issues → you may work on ROADMAP tasks first, interleaving P2 fixes
3. After resolving → move it to the "Resolved" section below, writing down the fix
4. Ran into a new blocker during work → add it here immediately

---

## 🔴 P0 — Hard Blockers

(None for now)

---

## 🟡 P1 — High Priority

(None for now)

---

## 🔵 P2 — Normal Priority

(None for now)

---

## ✅ Resolved

### ~~B-004: HiDPI virtual display triggers the system mirroring UI + mouse movement stutter~~
- **Fix**: `CGConfigureDisplayMirrorOfDisplay` triggers hardware mirroring mode on Apple Silicon, which is a dead end. Switched to the same plist override approach as BetterDisplay: write `scale-resolutions` to `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-XXXX`, which requires administrator privileges (NSAppleScript); after enabling, reconnect the display for it to take effect. All mirroring-related code has been removed (enableHiDPIVirtual/disableHiDPIVirtual/hiDPIMirrorMap, etc.).
- **Resolved on**: 2026-03-05
- **Lesson**: There are only two HiDPI approaches on macOS: (1) plist override (the BetterDisplay approach, requires admin + reconnect) (2) a pure CGVirtualDisplay virtual display (does not mirror a physical screen). ❌ Never use CGConfigureDisplayMirrorOfDisplay.

### ~~B-002: CGVirtualDisplay is a private API with no public header~~
- **Fix**: The user approved use of the private API. Created FreeDisplay-Bridging-Header.h declaring the CGVirtualDisplay + IOAVService interfaces; VirtualDisplayService now implements full virtual display creation/destruction.
- **Resolved on**: 2026-03-03

### ~~B-003: DDC brightness control has no effect on some external displays~~
- **Fix**: Root cause confirmed: the IOFramebuffer I2C API used by DDCService does not work at all on Apple Silicon. Added the IOAVService ARM64 DDC path (locating external displays via DCPAVServiceProxy), plus a CGSetDisplayTransferByTable gamma table software brightness fallback.
- **Resolved on**: 2026-03-03

### ~~B-001: DisplayInfo.name only shows "Display N" instead of the real display name~~
- **Fix**: Use `IOServiceMatching("IODisplayConnect")` + `IODisplayCreateInfoDictionary` to enumerate all IODisplayConnect services, match by DisplayVendorID + DisplayProductID, and take the product name of the first locale from the DisplayProductName dictionary; the built-in display directly returns "Built-in Display"
- **Resolved on**: 2026-03-02
- **Lesson**: Integer values in IOKit CF dictionaries may be of type Int rather than UInt32, so both types must be attempted

### ~~B-000: Missing GENERATE_INFOPLIST_FILE causes build failure~~
- **Fix**: Added `GENERATE_INFOPLIST_FILE: YES` to project.yml settings
- **Resolved on**: 2026-03-02
- **Lesson**: xcodegen does not generate Info.plist automatically; it must be enabled explicitly

### ~~B-000b: DDCService static singleton Swift 6 concurrency error~~
- **Fix**: Marked the class `@unchecked Sendable` and set `SWIFT_STRICT_CONCURRENCY: minimal` in project.yml
- **Resolved on**: 2026-03-02
- **Lesson**: Under Swift 6 strict concurrency checking, singletons need an explicit Sendable marking
