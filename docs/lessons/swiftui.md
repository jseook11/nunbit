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

### L-040: Never write display hardware from an expandable view's `onAppear`
- **Symptom**: Opening **Image Adjustment** visibly stuttered. The panel was persisted as expanded, so every menu open re-ran the apply.
- **Cause**: `MenuBarExtra` tears its content down on close and rebuilds it on open. `ImageAdjustmentView.onAppear` loaded saved state and called `GammaService.apply` synchronously — a `CGSetDisplayTransfer*` WindowServer IPC — in the middle of the spring insertion animation. It was also redundant: `DisplayManager.scheduleDisplayStateRestore` already re-applies gamma at launch and after every display-configuration change.
- **Fix**: load saved values only (into the view model) and let `DisplayManager` own hardware re-assertion. Commit writes only when a control is released.
- **Lesson**: "The view appeared" is not a state-loss event. Re-assert shared hardware state at the event that resets it, not on every appearance — especially on the main thread inside an animation.
- **Date**: 2026-10-21

### L-041: With many independent controls, observe the property — not the container
- **Symptom**: Dragging one of the 13 Image Adjustment sliders re-laid out the whole menu; the panel also re-rendered ~2×/s while idle.
- **Cause**: every value was `@State` on the container, so one tick invalidated the whole body (13 rows + the `MenuBarExtra` `ScrollView`). `ImageAdjustmentView` also held `@ObservedObject var display`, so the brightness poll's `display.brightness` assignment rebuilt the panel even though the view only used `display.displayID`.
- **Fix**: an `@Observable` model + per-row `ReferenceWritableKeyPath` bindings (a row reads only its own value), a plain `let` for the immutable `DisplayInfo`, change-thresholded brightness publishes, and quantization committing on release only (the editing-changed closure fires at both ends).
- **Lesson**: `@Observable` tracks property access, not object identity — but only if each row reads the property itself. Passing values through a container body re-introduces whole-panel invalidation.
- **Date**: 2026-10-21
