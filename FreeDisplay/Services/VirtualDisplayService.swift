import CoreGraphics
import Foundation
import IOKit

// CGVirtualDisplay and CGVirtualDisplaySettings are ObjC objects without Sendable
// conformance, but we only use them sequentially (create on main → apply on background
// → register the result on main), so @unchecked Sendable is safe here.
extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

/// Manages virtual display configurations and creates CGVirtualDisplay instances
/// using the private CGVirtualDisplay API declared in the bridging header.
@MainActor
final class VirtualDisplayService: ObservableObject, @unchecked Sendable {
    static let shared = VirtualDisplayService()
    private init() {
        loadConfigs()
    }

    // MARK: - Config Model

    struct VirtualDisplayConfig: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        /// Logical desktop width in points. For a HiDPI display the backing store is 2×.
        var width: Int
        /// Logical desktop height in points. For a HiDPI display the backing store is 2×.
        var height: Int
        var refreshRate: Double
        var hiDPI: Bool
        var autoCreate: Bool

        init(id: UUID = UUID(), name: String, width: Int, height: Int,
             refreshRate: Double = 60.0, hiDPI: Bool = true, autoCreate: Bool = false) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
            self.hiDPI = hiDPI
            self.autoCreate = autoCreate
        }
    }

    // MARK: - State

    @Published var configs: [VirtualDisplayConfig] = []

    /// Active config IDs — populated only after the display is confirmed online.
    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects.
    /// Releasing an entry causes the virtual display to disappear immediately.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]

    /// The launch-time autoCreate pass. Kept so it can be cancelled on termination.
    private var autoCreateTask: Task<Void, Never>?

    private let configsKey = "fd.VirtualDisplayConfigs"
    private static let virtualVendorID: UInt32 = 0xEEEE
    private static let maxDimension = 16_384
    private static let pixelsPerInch: Double = 110.0

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    /// True only when the service has a live object and its display is actually online.
    /// `activeConfigIDs` is bookkeeping; WindowServer can remove a display without telling us.
    func isOnline(_ configID: UUID) -> Bool {
        guard let virtualDisplay = activeDisplayObjects[configID] else { return false }
        let id = virtualDisplay.displayID
        return id != kCGNullDirectDisplay && CGDisplayIsOnline(id) != 0
    }

    func displayID(for configID: UUID) -> CGDirectDisplayID? {
        guard let id = activeDisplayObjects[configID]?.displayID,
              id != kCGNullDirectDisplay else { return nil }
        return id
    }

    /// Returns true for a display managed by this service, or any other display
    /// advertising FreeDisplay's virtual vendor ID (for orphan/stale displays).
    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        if activeDisplayObjects.values.contains(where: { $0.displayID == displayID }) {
            return true
        }
        return CGDisplayVendorNumber(displayID) == Self.virtualVendorID
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the given config using the CGVirtualDisplay private API.
    /// Returns true only after the display is confirmed online. The CGVirtualDisplay object
    /// is retained in `activeDisplayObjects`.
    ///
    /// Concurrency: descriptor construction and `CGVirtualDisplay(descriptor:)` run on the
    /// main actor (required by WindowServer), while `apply(_:)` runs off-main because it can
    /// block on WindowServer IPC.
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        guard (1...Self.maxDimension).contains(config.width),
              (1...Self.maxDimension).contains(config.height),
              config.refreshRate.isFinite,
              config.refreshRate > 0 else {
            return false
        }

        // Already alive — do not create a duplicate.
        if isOnline(config.id) { return true }
        if activeDisplayObjects[config.id] != nil {
            _ = destroy(configID: config.id)
        }

        let logicalWidth = config.width
        let logicalHeight = config.height
        let backingWidth = config.hiDPI ? logicalWidth * 2 : logicalWidth
        let backingHeight = config.hiDPI ? logicalHeight * 2 : logicalHeight
        guard backingWidth <= Self.maxDimension, backingHeight <= Self.maxDimension else {
            return false
        }

        let identity = Self.identity(for: config.id)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.sizeInMillimeters = CGSize(
            width: Double(logicalWidth) / Self.pixelsPerInch * 25.4,
            height: Double(logicalHeight) / Self.pixelsPerInch * 25.4
        )
        // maxPixels is the backing-store limit. For HiDPI the logical mode uses half
        // of this, so a 1920×1080 logical display needs a 3840×2160 backing limit.
        descriptor.maxPixelsWide = UInt32(backingWidth)
        descriptor.maxPixelsHigh = UInt32(backingHeight)
        descriptor.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "FreeDisplay Virtual"
            : config.name
        descriptor.vendorID = Self.virtualVendorID
        descriptor.productID = identity.product
        descriptor.serialNum = identity.serial
        // Leave descriptor.queue unset: the current macOS 26 behavior accepts nil and
        // setting it has caused creation failures in earlier experiments.

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0

        var modes: [CGVirtualDisplayMode] = []
        for rate in Self.refreshRates(preferred: config.refreshRate) {
            // Logical (desktop) mode.
            modes.append(CGVirtualDisplayMode(
                width: UInt(logicalWidth),
                height: UInt(logicalHeight),
                refreshRate: rate
            ))
            // Native backing mode. Present for HiDPI so macOS can offer both
            // "looks like 1920×1080" and the native 3840×2160 mode.
            if config.hiDPI {
                modes.append(CGVirtualDisplayMode(
                    width: UInt(backingWidth),
                    height: UInt(backingHeight),
                    refreshRate: rate
                ))
            }
        }
        settings.modes = modes

        // Apply off-main: this blocks on WindowServer IPC.
        let vd = virtualDisplay
        let s = settings
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applyResult else { return false }

        // displayID and the mode catalog are populated asynchronously after apply().
        // Poll instead of checking immediately; an immediate check rejects valid displays.
        var displayID: CGDirectDisplayID = kCGNullDirectDisplay
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            displayID = virtualDisplay.displayID
            if displayID != kCGNullDirectDisplay && CGDisplayIsOnline(displayID) != 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard displayID != kCGNullDirectDisplay, CGDisplayIsOnline(displayID) != 0 else {
            #if DEBUG
            print("[VirtualDisplayService] create failed: displayID never came online")
            #endif
            return false
        }

        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)
        return true
    }

    /// Destroys all active virtual displays. Called on app termination to avoid
    /// leaving stale displays registered with WindowServer.
    func destroyAll() {
        autoCreateTask?.cancel()
        autoCreateTask = nil
        activeDisplayObjects.removeAll()
        activeConfigIDs.removeAll()
    }

    /// Destroys the virtual display associated with `configID`.
    /// ARC releases the CGVirtualDisplay object, which makes the display disappear.
    @discardableResult
    func destroy(configID: UUID) -> Bool {
        guard activeDisplayObjects[configID] != nil else {
            return false
        }
        activeDisplayObjects.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)
        return true
    }

    /// Creates the display for an existing config without changing the config list.
    @discardableResult
    func activate(configID: UUID) async -> Bool {
        guard let config = configs.first(where: { $0.id == configID }) else { return false }
        return await create(config: config)
    }

    /// Destroys the display while keeping its config for later activation.
    @discardableResult
    func deactivate(configID: UUID) -> Bool {
        destroy(configID: configID)
    }

    /// Re-creates active displays that WindowServer dropped after wake/display sleep.
    func reconcileActiveDisplays() async {
        for config in configs where activeConfigIDs.contains(config.id) {
            if isOnline(config.id) { continue }

            #if DEBUG
            print("[VirtualDisplayService] reconciling dropped virtual display '\(config.name)'")
            #endif
            activeDisplayObjects.removeValue(forKey: config.id)
            activeConfigIDs.remove(config.id)
            _ = await create(config: config)
        }
    }

    // MARK: - Config Management

    @discardableResult
    func addAndCreate(_ config: VirtualDisplayConfig) async -> Bool {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            // Editing an existing config: replace the live display and persist the change.
            if activeDisplayObjects[config.id] != nil {
                _ = destroy(configID: config.id)
            }
            configs[index] = config
            saveConfigs()
            return await create(config: config)
        }

        // Create first; only persist on success to avoid stale config if process crashes.
        if await create(config: config) {
            configs.append(config)
            saveConfigs()
            return true
        }
        return false
    }

    func removeConfig(id: UUID) {
        destroy(configID: id)
        configs.removeAll { $0.id == id }
        saveConfigs()
    }

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        else { return }
        configs = decoded

        // Re-create virtual displays marked autoCreate after WindowServer stabilises.
        let autoCreateConfigs = configs.filter { $0.autoCreate }
        guard !autoCreateConfigs.isEmpty else { return }

        autoCreateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }

            for config in autoCreateConfigs {
                guard !Task.isCancelled else { return }

                // The user may have deleted the config while we were waiting.
                guard self.configs.contains(where: { $0.id == config.id }) else { continue }

                // A display from a previous process may still be online. We cannot adopt
                // it (we do not own its CGVirtualDisplay object), so do not create a
                // duplicate with the same identity.
                if let existing = self.onlineVirtualDisplay(for: config) {
                    #if DEBUG
                    print("[VirtualDisplayService] autoCreate skipped — existing display \(existing) for '\(config.name)'")
                    #endif
                    continue
                }

                _ = await self.create(config: config)
            }
        }
    }

    /// Finds an online virtual display with the same stable identity as `config`.
    /// Replaces the old `CGDisplayIOServicePort == 0` check, which returns 0 for
    /// physical displays on current macOS and therefore misclassifies everything.
    private func onlineVirtualDisplay(for config: VirtualDisplayConfig) -> CGDirectDisplayID? {
        let identity = Self.identity(for: config.id)

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return nil }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        for id in displayIDs where CGDisplayIsOnline(id) != 0 {
            guard CGDisplayVendorNumber(id) == Self.virtualVendorID,
                  CGDisplayModelNumber(id) == identity.product,
                  CGDisplaySerialNumber(id) == identity.serial else { continue }
            return id
        }
        return nil
    }

    private func saveConfigs() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: configsKey)
    }

    // MARK: - Stable Identity

    /// Derives a stable product/serial pair from the config UUID. Unlike Swift's
    /// `hashValue`, this is deterministic across processes and launches, so the
    /// display UUID stays stable for WindowServer and presets.
    private static func identity(for id: UUID) -> (product: UInt32, serial: UInt32) {
        let u = id.uuid
        let bytes: [UInt8] = [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
        ]

        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
        }

        var product = word(0)
        var serial = word(4)
        if product == 0 { product = 1 }
        if serial == 0 { serial = 1 }
        return (product, serial)
    }

    private static func refreshRates(preferred: Double) -> [Double] {
        var result: [Double] = []
        for rate in [preferred, 60.0, 50.0] where rate.isFinite && rate > 0 {
            if !result.contains(rate) { result.append(rate) }
        }
        return result
    }
}
