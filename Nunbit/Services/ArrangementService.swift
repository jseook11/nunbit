import Foundation
import CoreGraphics

/// Service for reading and setting display positions in the global coordinate space.
/// On macOS, the display whose bounds contain origin (0, 0) is the main display
/// (the one that shows the Dock and menu bar).
@MainActor
class ArrangementService {
    static let shared = ArrangementService()
    private init() {}

    /// Moves the given display to the specified position in the global coordinate space.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
        await apply(origins: [(id: displayID, x: Int32(x), y: Int32(y))])
    }

    /// Applies all display origins in a single Begin→Configure→Complete transaction.
    ///
    /// Important: `CGCompleteDisplayConfiguration` invalidates `config` on both success
    /// and failure. Never call `CGCancelDisplayConfiguration` after it — that is a
    /// use-after-free. Cancel only when a `CGConfigure...` call fails *before* completion.
    @discardableResult
    func apply(origins: [(id: CGDirectDisplayID, x: Int32, y: Int32)]) async -> Bool {
        guard !origins.isEmpty else { return false }

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }

            for item in origins {
                let result = CGConfigureDisplayOrigin(cfg, item.id, item.x, item.y)
                guard result == .success else {
                    // The transaction has not been completed yet, so the config is
                    // still valid and must be cancelled to roll back.
                    CGCancelDisplayConfiguration(cfg)
                    return false
                }
            }

            // On return (success or failure) the config is no longer valid.
            return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        }
    }

    /// Makes the target display the main display by translating the whole layout so
    /// the target lands at origin (0, 0). The relative arrangement of every other
    /// display is preserved, which avoids the overlap/jump caused by swapping origins.
    ///
    /// Online display IDs are read from CoreGraphics rather than a cached
    /// `DisplayInfo` list: a virtual display can come online before DisplayManager's
    /// next refresh, and a stale list would reject a valid target.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setAsMainDisplay(_ targetID: CGDirectDisplayID) async -> Bool {
        guard CGDisplayIsOnline(targetID) != 0 else { return false }
        if CGDisplayIsMain(targetID) != 0 { return true }

        let targetBounds = CGDisplayBounds(targetID)
        let dx = -Int(targetBounds.origin.x)
        let dy = -Int(targetBounds.origin.y)

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let origins: [(id: CGDirectDisplayID, x: Int32, y: Int32)] = displayIDs
            .filter { CGDisplayIsOnline($0) != 0 }
            .map { id in
                let bounds = CGDisplayBounds(id)
                return (
                    id: id,
                    x: Int32(bounds.origin.x) + Int32(dx),
                    y: Int32(bounds.origin.y) + Int32(dy)
                )
            }

        guard origins.contains(where: { $0.id == targetID }) else { return false }
        return await apply(origins: origins)
    }
}
