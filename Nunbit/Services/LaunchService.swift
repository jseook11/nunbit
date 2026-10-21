import Foundation
import ServiceManagement

/// Manages "Launch at Login" using SMAppService (macOS 13+).
@MainActor
final class LaunchService: @unchecked Sendable {
    static let shared = LaunchService()
    private init() {}

    // MARK: - State

    /// The authoritative state, read straight from `SMAppService` — never from UserDefaults.
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// True when the login item is registered but macOS still wants the user to approve it
    /// in System Settings → General → Login Items. The toggle cannot be "on" in that state.
    var requiresApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    // MARK: - Messages

    private static let enableFailedMessage =
        "Could not enable Launch at Login. Move Nunbit to /Applications and try again."
    private static let disableFailedMessage =
        "Could not disable Launch at Login. Please try again."
    private static let approvalMessage =
        "Launch at Login needs your approval: allow Nunbit in System Settings → General → Login Items."

    // MARK: - Enable / Disable

    @discardableResult
    func enable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return true
            } catch {
                #if DEBUG
                print("[LaunchService] register failed: \(error)")
                #endif
                return false
            }
        }
        return false
    }

    @discardableResult
    func disable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                return true
            } catch {
                #if DEBUG
                print("[LaunchService] unregister failed: \(error)")
                #endif
                return false
            }
        }
        return false
    }

    // MARK: - Apply requested state

    /// Applies the state the user asked for and reports what actually happened.
    ///
    /// Registration can fail silently from the caller's point of view — the app may not be
    /// in /Applications, or macOS may leave the item waiting for approval — so the caller
    /// must read `isEnabled` afterwards and display *that*, never the requested value.
    ///
    /// - Parameter enabled: the state the user asked for.
    /// - Returns: `nil` when the requested state is now in effect, otherwise a message to
    ///   show the user.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else {
            return "Launch at Login requires macOS 13 or later."
        }

        if enabled {
            if isEnabled { return nil }
            // Already registered, just not approved: registering again would throw.
            if requiresApproval { return Self.approvalMessage }
            guard enable() else { return Self.enableFailedMessage }
        } else {
            // Nothing registered (or the app is not installed): already off.
            if !isEnabled && !requiresApproval { return nil }
            guard disable() else { return Self.disableFailedMessage }
        }

        // Trust the system, not the call: verify the state really changed.
        if isEnabled == enabled { return nil }
        return requiresApproval
            ? Self.approvalMessage
            : (enabled ? Self.enableFailedMessage : Self.disableFailedMessage)
    }

    /// Toggles the current state. See `setEnabled(_:)` for the return value.
    @discardableResult
    func toggle() -> String? {
        setEnabled(!isEnabled)
    }
}
