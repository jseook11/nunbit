# Lessons Learned Index — Nunbit

> Updated: 2026-03-05

## Topic Index

| Topic | File | Entries |
|------|------|------|
| IOKit / DDC / Rotation / Ambient Light / Display Matching / Apple Silicon | [iokit.md](iokit.md) | L-003 ~ L-005, L-033 + general entries |
| CoreGraphics / HiDPI / CGVirtualDisplay | [coregraphics.md](coregraphics.md) | L-006, L-007, L-020 ~ L-031 + general entries |
| SwiftUI / MenuBarExtra / UI Animation / DDC Cache / Performance | [swiftui.md](swiftui.md) | general entries |
| Cross-Service Collaboration / Concurrency / Resource Management | [services.md](services.md) | L-008 ~ L-019, L-032 |
| Xcode Build / Phase Wrap-up | [build.md](build.md) | general entries |

## Permanent Rules (High-Frequency Pitfalls)

1. **After adding a new Swift source file you must run `xcodegen generate`** — otherwise the compiler does not know about the new file ("cannot find in scope")
2. **Two services must not each write the same CoreGraphics resource** — designate a single writer; other parties influence it through an interface (see services.md L-008)
3. **When passing self to a C callback, always use `Unmanaged.passRetained`, and pair it with a release on deregistration** — passUnretained is a dangling-pointer time bomb
4. **❌ CGConfigureDisplayMirrorOfDisplay for HiDPI** — on Apple Silicon this triggers hardware mirroring + mouse stutter, ✅ use a plist override (/Library/Displays/)
