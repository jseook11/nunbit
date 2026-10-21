# Lessons Learned — IOKit

> Updated: 2026-03-05

## IOKit / DDC

- In the CF dictionary returned by `IODisplayCreateInfoDictionary`, `DisplayVendorID` and `DisplayProductID` are of type `Int` (not `UInt32`); try a UInt32 cast first, then an Int cast
- `IODisplayCreateInfoDictionary` returns `Unmanaged<CFDictionary>?`, so you need `.takeRetainedValue()` to get the value (ARC-managed)
- The matching argument of `IOServiceGetMatchingServices` consumes the CFDictionary's reference; you do not need to release it manually
- IOKit's I2C submodule is an `explicit module`, so `import IOKit` does not include it → you need `import IOKit.i2c` (I2C functions) and `import IOKit.graphics` (IODisplay*FloatParameter functions)
- `IOI2CRequest` is inside a `#pragma pack(push, 4)` struct, and the `sendTransactionType`/`replyTransactionType` fields are of type `IOOptionBits` (UInt32, not UInt8)
- `kIODisplayBrightnessKey` is `#define "brightness"`; Swift does not bridge string macros automatically → use `"brightness" as CFString` directly
- Swift's `Array.withUnsafeMutableBytes` holds an exclusive mutable borrow, so you cannot subscript the original array inside the closure → read data through the raw buffer pointer (`replyRaw.bindMemory(to: UInt8.self)`), or capture `.count` beforehand outside the closure
- `IOFBCopyI2CInterfaceForBus(framebuffer, busIndex, &interface)` is a cleaner API than manually walking the IOFramebufferI2CInterface child nodes; it is recommended
- If a `BrightnessService` method needs to access `@MainActor`-isolated `DisplayInfo` properties, mark it `@MainActor`; the actual DDC I/O is executed asynchronously by the ddcQueue inside DDCService, so it does not block the MainActor

## IOKit / Screen Rotation (Phase 4)

- `CGDisplayIOServicePort` is now completely **unavailable** in the latest macOS SDK (not deprecated) and errors out immediately, so you must use IOKit registry traversal instead
- Alternative: traverse `IODisplayConnect` → match by vendor/model → `IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)` to obtain the IOFramebuffer (exactly the same pattern as DDCService.framebufferService)
- Screen rotation: trigger with `IORegistryEntrySetCFProperty(fb, "IOFBTransform", NSNumber(value: index))` + `IOServiceRequestProbe(fb, 0x00000400)`; rotation index = 0/1/2/3 corresponds to 0°/90°/180°/270°
- `import IOKit.graphics` is necessary for the graphics constants required by `IOServiceRequestProbe`

## IOKit / Ambient Light Sensor (Phase 11)

- `AppleLMUController` is an IOKit service, obtained via `IOServiceGetMatchingService`; after opening a connection with `IOServiceOpen`, use `IOConnectCallMethod(port, 0, nil, 0, nil, 0, &output, &outputCount, nil, &outputStructSize)` to read the UInt64 values of the two channels (left/right) of the sensor
- The struct size parameter of `IOConnectCallMethod` is `Int` (size_t = Int in Swift) and cannot be nil → you must pass `0` or a pointer to a variable (`&outputStructSize`)
- After creating a new Swift file, if other files reference types in the new file, you must first run `xcodegen generate` to regenerate the xcodeproj, otherwise "cannot find in scope"
- When accessing properties of another `@MainActor` class inside the `init` of a `@MainActor` class, the `init` must also be marked `@MainActor`, otherwise Swift 6 strict concurrency reports an error

## IOKit / Built-in Brightness

### L-039: The built-in brightness IOKit path is dead on macOS 26
- **Symptom**: The brightness slider for the MacBook panel moves, but the screen never changes.
- **Cause**: Measured on macOS 26 (Darwin 25.5): `CGDisplayIOServicePort(builtinID)` returns `0`, and `IOServiceMatching("IODisplayConnect")` yields **zero** services. `IODisplayGet/SetFloatParameter` therefore never reaches the internal panel, and the whole fallback loop is a no-op. `CoreDisplay_Display_GetUserBrightness` also returned a constant `1.0` while the real panel was at `0.80`.
- **Fix**: Use the private DisplayServices framework via `dlopen`/`dlsym`: `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` / `DisplayServicesCanChangeBrightness`. Verified `rc=0` on get and set, with the readback matching the requested value. Keep the IOKit and CoreDisplay paths as fallbacks for macOS 14/15 and Intel.
- **Lesson**: An API that still links is not an API that still works. Probe the real data path per OS version, and prefer `nil` over a plausible constant — the stale `1.0` quietly fed the wrong value into Auto Brightness.
- **Date**: 2026-10-21

## IOKit Display Matching (Phase 13-15)

### L-003: vendor+model IOKit matching is unreliable
- **Symptom**: DisplayInfo shows the name "Display 2" and the DDC brightness slider has no effect
- **Cause**: The values returned by CGDisplayVendorNumber/ModelNumber and IOKit's DisplayVendorID/DisplayProductID are not necessarily consistent (at least they do not match on the HKC H2435Q), causing IODisplayConnect service matching to fail
- **Fix**: Use NSScreen.localizedName for the name (system API, most reliable); use CGDisplayIOServicePort for IOKit service lookup (deprecated but still functional)
- **Lesson**: Do not assume different frameworks (CoreGraphics vs IOKit) report consistent identifiers for the same hardware. Prefer system-level APIs (NSScreen) over low-level IOKit lookups
- **Date**: 2026-03-03

### L-004: Do not make microsecond-level operations async
- **Symptom**: Phase 14 changed the name lookup in DisplayInfo.init to async, causing users to see "Display N" flash before it updated to the real name (sometimes it never updated)
- **Cause**: The IOKit name lookup only takes microseconds; making it async introduced a race condition (refreshDisplays may be called multiple times, with a later call overwriting an earlier async result)
- **Fix**: Roll back to a synchronous call
- **Lesson**: Making something async is only worthwhile for genuinely slow operations (>100ms). Making microsecond-level operations async only adds complexity and bugs
- **Date**: 2026-03-03

## Apple Silicon DDC (Phase 17)

### L-005: IOFramebuffer I2C API does not work at all on Apple Silicon
- **Symptom**: DDC brightness/contrast control has no effect on any external display
- **Cause**: `IOFBCopyI2CInterfaceForBus` / `IOI2CSendRequest` are IOFramebuffer APIs from the Intel era; on Apple Silicon (M1/M2/M3/M4) these function calls return silently without sending any I2C data
- **Fix**: Use the private IOAVService API (`IOAVServiceCreateWithService` + `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`), locating external displays through the DCPAVServiceProxy IOKit service
- **Lesson**: macOS on different CPU architectures uses completely different display communication APIs. MonitorControl and BetterDisplay both use IOAVService. See alinpanaitiu.com/blog/journey-to-ddc-on-m1-macs/
- **Date**: 2026-03-03

### L-033: A successful DDC I2C read can still return garbage
- **Symptom**: On an MSI MD271UL, dragging the brightness slider moves the UI value but the panel never changes. The same happened for every VCP code.
- **Cause**: The monitor never answers Get VCP. `IOAVServiceReadI2C` still returns `kIOReturnSuccess` with fixed stale bytes (`6e 80 be d0 a4 0a f9 ab 2f 9a 2d 3a`). `DDCService` parsed bytes 6–9 unconditionally, producing `max=63915` / `current=12186` (19%). Every brightness write was then scaled against that bogus max and landed far outside the panel's real 0–100 range, so the monitor ignored it. Writes themselves work — a manual Set VCP 0x10=20 visibly dimmed the screen.
- **Fix**: Validate the reply frame before parsing: `reply[0] == 0x6E`, `(reply[1] & 0x7F) == 0x08`, `reply[2] == 0x02`, `reply[3] == 0x00`, `reply[4] == command`. Invalid → return nil and never store `max`. A failed read must not mark DDC unavailable: some panels accept Set VCP but not Get VCP. Fall back to an assumed 0–100 range, and decide availability from write success/failure.
- **Lesson**: I2C transaction success ≠ valid DDC/CI reply. Always validate the frame header and length byte before trusting the payload, and never denormalize using an unvalidated max.
- **Date**: 2026-10-21

### L-046: Two identical monitors get their DDC brightness swapped
- **Symptom**: With two identical MSI MD271UL panels connected, the menu row for the main display adjusts the other panel's brightness. Gamma/colour adjustments (written with `CGSetDisplayTransferByTable(displayID, …)`) land on the correct panel; only DDC brightness is swapped.
- **Cause**: `DDCService.buildAVServiceMap` could not match `DCPAVServiceProxy` nodes to `CGDirectDisplayID`s. The DCPEXT ancestor chain exposes no `DisplayVendorID`/`DisplayProductID` (checked on macOS 26), and `CGDisplayIOServicePort` returns 0, so matching fell back to pairing `externalIDs.sorted()` with the AV services in IORegistry enumeration order. Both panels report the same vendor (0x3669), model (12472) and serial (0), so the two AV services are indistinguishable that way, and the index order happens to be the reverse of the display-ID order.
- **Fix**: Match on the panel's EDID instead of vendor/model/index:
  1. `CoreDisplay_DisplayCreateInfoDictionary(displayID)` (dlsym) → `IODisplayLocation` → `IORegistryEntryFromPath` → the framebuffer's `"EDID UUID"` property identifies the display.
  2. `IOAVServiceCopyEDID(avService, &edid)` (dlsym, IOKit export) gives the same EDID for each AV service; strip the dashes from the framebuffer's `"EDID UUID"` and compare it with the hex of EDID bytes 8–23 (the 16-byte header region IOKit formats as 4-2-2-2-6), so both sides compare equal.
  3. Match exact UUIDs first; keep vendor/product and index assignment only as fallbacks. Exclude virtual displays (`VirtualDisplayService.virtualVendorID`) from the candidate list so they cannot steal a physical service.
- **Lesson**: "Identical" monitors are never identical at the EDID level — manufacture date, serial descriptor and checksum differ per unit. Commodity identifiers (`CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber`) are not a display identity; EDID is. `CGDisplayIOServicePort` is gone on macOS 26, so `CoreDisplay_DisplayCreateInfoDictionary` + `IODisplayLocation` is the remaining bridge from display ID to framebuffer.
- **Date**: 2026-10-21
