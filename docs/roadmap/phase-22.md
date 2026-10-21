# Phase 22: Auto Brightness Rewrite — Following the Built-in Display

> Status: Completed | Estimate: High complexity

## Goal

Rewrite the auto brightness feature: abandon the Intel-only AppleLMUController approach and instead **monitor brightness changes on the built-in display and mirror them proportionally to the external display**. This is the approach BetterDisplay uses, and it is stable and reliable on Apple Silicon.

## Technical Approach

macOS already adjusts built-in display brightness automatically (based on ambient light). Nunbit only needs to:
1. Poll the current built-in brightness every 2 seconds (`IODisplayGetFloatParameter` or the CoreDisplay private API)
2. If the brightness changes beyond a threshold (2%), mirror it to the external display according to the user-defined mapping curve
3. Set the external display brightness via DDC VCP 0x10 or the gamma table software fallback

**Key APIs**:
- Built-in brightness read: `CoreDisplay_Display_GetUserBrightness(displayID)` — reliable on Apple Silicon
- Fallback: `IODisplayGetFloatParameter(service, kNilOptions, kIODisplayBrightnessKey, &brightness)`
- External brightness write: reuse the existing `BrightnessService.setBrightness()`

## Tasks

### Task 1: Rewrite AutoBrightnessService — follow mode
- [x] Remove the `AppleLMUController` sensor polling logic (delete `findSensorPort`, `readAmbientLux`, etc. entirely)
- [x] Add `readBuiltinBrightness() -> Double?`: read the current built-in brightness (0.0-1.0)
  - Preferred: `@_silgen_name("CoreDisplay_Display_GetUserBrightness") func CoreDisplay_Display_GetUserBrightness(_ display: CGDirectDisplayID) -> Double`
  - Fallback: `IODisplayGetFloatParameter` iterating over IODisplayConnect
- [x] Add `@Published var builtinBrightness: Double = 0` to replace `lastLux`
- [x] Change the polling logic to: read built-in brightness → if the change is > 2% → compute the external target brightness from the mapping curve → call BrightnessService
- [x] Mapping curve: `externalTarget = builtinBrightness * sensitivityMultiplier` (sensitivity ranges from 0.5-1.5, default 1.0)
- [x] Keep the 30-second manual adjustment cooldown
- [x] Keep the UserDefaults keys `fd.AutoBrightnessEnabled` and `fd.AutoBrightnessSensitivity`

**Implementation hints**: `CoreDisplay_Display_GetUserBrightness` is a private API but exists stably on macOS 14+; open-source projects such as MonitorControl and Lunar use it. Declaring it with `@_silgen_name` is enough. If `CoreDisplay_Display_GetUserBrightness` returns 0 (on certain OS versions), fall back to IODisplayGetFloatParameter.

### Task 2: Rewrite AutoBrightnessView — adapt to the new approach
- [x] Remove the `lastLux` display (there is no lux value anymore)
- [x] Show "Built-in brightness: XX%" instead (`builtinBrightness` rendered live)
- [x] Change the sensor-unavailable message to "No built-in display detected" (shown only when there is no built-in display)
- [x] Keep the Sensitivity slider, with the label changed to "Sync ratio"
- [x] Add explanatory text: "Automatically follows the built-in display brightness to adjust the external display"

**Implementation hints**: Change the `sensorUnavailable` logic to check `builtinBrightness > 0 || hasBuiltinDisplay` instead of checking lux.

### Task 3: Verify built-in brightness reading
- [x] Write a temporary test: print `CoreDisplay_Display_GetUserBrightness(builtinDisplayID)` to `~/Desktop/brightness_test.log` at AppDelegate launch
- [x] Adjust the brightness slider manually and confirm the reading changes in real time (0.0-1.0 range)
- [x] If CoreDisplay returns 0 or an unexpected value → switch to the IODisplayGetFloatParameter path
- [x] Delete the temporary test code after the test passes

**Implementation hints**: Filter the built-in display ID with `CGDisplayIsBuiltin(displayID)`. File logging is more reliable than print for debugging (a menu bar app has no stdout).

### Task 4: Build verification + integration testing
- [x] Build passes
- [x] Real-world test: enable auto brightness → adjust the MacBook brightness → observe whether the external display follows
- [x] Edge-case tests: unplug the external display → no crash; no built-in display → show the message
- [x] Update the AutoBrightnessService description in `docs/codemap/`

## Acceptance Criteria

```bash
# Build passes
xcodebuild -scheme Nunbit -configuration Debug build 2>&1 | tail -3

# Manual tests
# 1. Enable auto brightness → adjust the MacBook brightness → external display brightness follows
# 2. Adjust the "Sync ratio" slider → the external display responds
# 3. Adjust the external display brightness manually → auto brightness does not override it for 30 seconds
# 4. Close the lid/unplug the display → no crash
```
