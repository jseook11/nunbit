import CoreGraphics
import Foundation

/// Provides hardware-level screen mirroring via CGDisplayConfiguration API.
final class MirrorService: @unchecked Sendable {
    static let shared = MirrorService()
    private init() {}

    // MARK: - Query

    /// Returns the source display that `displayID` is mirroring, or nil if not mirroring.
    func mirrorSource(for displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let source = CGDisplayMirrorsDisplay(displayID)
        guard source != kCGNullDirectDisplay else { return nil }
        return source
    }

    /// Returns true when `displayID` is currently mirroring another display.
    func isMirroring(_ displayID: CGDirectDisplayID) -> Bool {
        mirrorSource(for: displayID) != nil
    }

    // MARK: - Enable

    /// Makes `target` mirror `source`.
    /// The entire Begin→Mirror→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true only when `target` actually mirrors `source` afterwards.
    @discardableResult
    func enableMirror(source: CGDirectDisplayID, target: CGDirectDisplayID) async -> Bool {
        // Mirroring a display onto itself is invalid and causes undefined CG behaviour.
        guard source != target else {
#if DEBUG
            print("[MirrorService] enableMirror: source == target (\(source)), ignoring")
#endif
            return false
        }
        // An offline display cannot join a mirror set; without this guard the
        // configuration would "succeed" while nothing happened.
        guard CGDisplayIsOnline(source) != 0, CGDisplayIsOnline(target) != 0 else {
#if DEBUG
            print("[MirrorService] enableMirror: source (\(source)) or target (\(target)) is offline")
#endif
            return false
        }

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }

            let result = CGConfigureDisplayMirrorOfDisplay(cfg, target, source)
            guard result == .success else {
                // Not completed yet: the config is still valid and must be cancelled.
                CGCancelDisplayConfiguration(cfg)
                return false
            }

            // `CGCompleteDisplayConfiguration` invalidates `config` on both success and
            // failure — never call CGCancelDisplayConfiguration afterwards.
            guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else { return false }

            // Report what actually happened rather than what was requested.
            return CGDisplayMirrorsDisplay(target) == source
        }
    }

    // MARK: - Query (source perspective)

    /// Returns true when `displayID` is acting as a mirror source —
    /// i.e., at least one other online display is cloning it.
    func isMirrorSource(_ displayID: CGDirectDisplayID) -> Bool {
        mirrorTargets(of: displayID) != nil
    }

    /// Returns the first display that is mirroring `sourceID`, or nil if none.
    func mirrorTargets(of sourceID: CGDirectDisplayID) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { $0 != sourceID && CGDisplayMirrorsDisplay($0) == sourceID }
    }

    // MARK: - Disable

    /// Stops `displayID` from mirroring.
    /// The entire Begin→Mirror→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true only when `displayID` is no longer mirroring anything afterwards.
    @discardableResult
    func disableMirror(displayID: CGDirectDisplayID) async -> Bool {
        guard CGDisplayIsOnline(displayID) != 0 else {
            // An offline display cannot be mirroring; the requested end state already holds.
            return CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
        }

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }

            let result = CGConfigureDisplayMirrorOfDisplay(cfg, displayID, kCGNullDirectDisplay)
            guard result == .success else {
                // Not completed yet: the config is still valid and must be cancelled.
                CGCancelDisplayConfiguration(cfg)
                return false
            }

            // `CGCompleteDisplayConfiguration` invalidates `config` on both success and
            // failure — never call CGCancelDisplayConfiguration afterwards.
            guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else { return false }

            // Report what actually happened rather than what was requested.
            return CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
        }
    }
}
