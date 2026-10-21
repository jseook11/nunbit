# Lessons Learned — SwiftUI / UI

> Updated: 2026-03-05

## SwiftUI / MenuBarExtra

- MenuBarExtra needs `.menuBarExtraStyle(.window)` to display custom SwiftUI views (the default is menu style, which only supports Button/Toggle)
- Hiding the Dock icon: set `INFOPLIST_KEY_LSUIElement: true` in project.yml; you do not need to set it manually in AppDelegate

## UI Animation / SwiftUI (Phase 12)

- `withAnimation(.easeInOut(duration: 0.2)) { state.toggle() }` is the simplest way to trigger an expand/collapse animation; you do not need `.animation(_, value:)` on the whole container
- `.transition(.opacity.combined(with: .move(edge: .top)))` is used for the enter/exit effect of expanded content, which visually looks like it slides out from below the button
- The shared icon helper `MenuItemIcon` (defined in MenuBarView.swift) can be used directly by all Views in the same Module, with no extra declaration needed
- Semantic colors in SwiftUI (green = protection/security, red = streaming, orange = brightness, gray = settings, purple = color management) convey functional meaning effectively without extra text labels

## DDC Performance Cache (Phase 12)

- DDC I2C reads have 50ms+ latency, and repeated reads triggered by the UI significantly hurt the experience → solve it with `NSLock` + dictionary cache + 5-second TTL; invalidate the corresponding cache entry immediately after a write
- The cache key is `[CGDirectDisplayID: [UInt8: VCPCacheEntry]]`, a two-level dictionary, allowing precise invalidation by display and VCP code
- `NSLock.lock()` / `unlock()` must be paired; using `defer { lock.unlock() }` is recommended, but note that defer still executes correctly on an early return

## SwiftUI Performance

- A `@Published` property change triggers a redraw of every View observing that ObservableObject → split state into multiple small ObservableObjects or localize it with `@State`
- Do not put synchronous IOKit/CG calls (such as `CGDisplayCopyColorSpace`) in a View's `body` → fetch them asynchronously with `@State` + `onAppear`/`task {}`
- The `isSwitching = true; syncCall(); isSwitching = false` pattern does not work: SwiftUI does not render in the middle of synchronous code → you must use async/await to give SwiftUI a chance to redraw
- Wrapping a shared singleton (`XXX.shared`) in `@StateObject` is an anti-pattern: each View rebuild may create a new subscription → use `@ObservedObject` for shared singletons
- The gamma table set by `CGSetDisplayTransferByFormula` is persistent at the kernel level and is not automatically restored when the View is destroyed → you must manually call `CGDisplayRestoreColorSyncSettings()` in `onDisappear` and when the app quits
