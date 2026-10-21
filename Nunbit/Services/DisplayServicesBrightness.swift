import Foundation
import CoreGraphics

/// Built-in display brightness through the private DisplayServices framework.
///
/// Why this exists: on macOS 26 the IOKit path used by `BrightnessService` is dead —
/// `CGDisplayIOServicePort` returns 0 and `IOServiceMatching("IODisplayConnect")` yields
/// zero services — so `IODisplayGet/SetFloatParameter` can never reach the internal panel.
/// DisplayServices is the API MonitorControl and Lunar use for Apple Silicon built-ins.
///
/// Loaded with `dlopen`/`dlsym` rather than linked, matching the project rule for private
/// frameworks (`CoreDisplay`, `IOAVService`): no undefined symbols at link time and the app
/// still launches on systems where the framework or symbol is absent.
enum DisplayServicesBrightness {
    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Int32

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let getFn: GetFn? = load("DisplayServicesGetBrightness", as: GetFn.self)
    private static let setFn: SetFn? = load("DisplayServicesSetBrightness", as: SetFn.self)
    private static let canChangeFn: CanChangeFn? = load("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)

    /// True when the framework exposed at least one of the brightness calls.
    static var isAvailable: Bool { getFn != nil || setFn != nil }

    /// Whether the display supports brightness changes. Falls back to "available" when the
    /// probe symbol is missing, so a framework change cannot silently disable the slider.
    static func canChange(_ displayID: CGDirectDisplayID) -> Bool {
        guard let canChangeFn else { return isAvailable }
        return canChangeFn(displayID) != 0
    }

    /// Current brightness in 0.0–1.0, or nil when the call is unavailable or fails.
    static func get(_ displayID: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(displayID, &value) == 0 else { return nil }
        return max(0.0, min(1.0, value))
    }

    /// Sets brightness (0.0–1.0). Returns true when the call succeeded.
    static func set(_ value: Float, for displayID: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        return setFn(displayID, max(0.0, min(1.0, value))) == 0
    }
}
