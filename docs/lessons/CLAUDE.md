# Lessons Learned Index — Nunbit

> Updated: 2026-10-21

## Topic Index

| Topic | File | Entries |
|------|------|------|
| IOKit / DDC / Rotation / Built-in Brightness / Display Matching / Apple Silicon | [iokit.md](iokit.md) | L-003 ~ L-005, L-033, L-039, L-046 + general entries |
| CoreGraphics / HiDPI / CGVirtualDisplay / ColorSync | [coregraphics.md](coregraphics.md) | L-006, L-007, L-020 ~ L-031, L-034, L-036, L-037, L-042, L-043 + general entries |
| SwiftUI / MenuBarExtra / UI Animation / DDC Cache / Performance | [swiftui.md](swiftui.md) | L-040, L-041, L-044, L-045, L-047 + general entries |
| Cross-Service Collaboration / Concurrency / Resource Management | [services.md](services.md) | L-008 ~ L-019, L-032, L-035, L-038 |
| Xcode Build / Phase Wrap-up | [build.md](build.md) | general entries |

## Permanent Rules (High-Frequency Pitfalls)

1. **After adding a new Swift source file you must run `xcodegen generate`** — otherwise the compiler does not know about the new file ("cannot find in scope")
2. **Two services must not each write the same CoreGraphics resource** — designate a single writer; other parties influence it through an interface (see services.md L-008)
3. **When passing self to a C callback, always use `Unmanaged.passRetained`, and pair it with a release on deregistration** — passUnretained is a dangling-pointer time bomb
4. **❌ CGConfigureDisplayMirrorOfDisplay for HiDPI** — on Apple Silicon this triggers hardware mirroring + mouse stutter, ✅ use a plist override (/Library/Displays/)
5. **Never key per-display persistence by `CGDirectDisplayID`** — use the stable display UUID (see services.md L-035)
6. **Never infer ownership of a shared privileged file from its existence** — merge, and record what you created (see coregraphics.md L-034)
7. **Every display-configuration change resets the transfer table of every display** — re-apply brightness and gamma afterwards, for all displays, not just the one that changed (see coregraphics.md L-036)
8. **A toggle reports the user's state, not this app's mechanism** — "HiDPI is on" means the display is running a HiDPI mode, not that a plist override exists (see coregraphics.md L-037)
