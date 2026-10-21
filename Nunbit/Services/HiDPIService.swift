import Foundation
import CoreGraphics
import IOKit

@MainActor
final class HiDPIService: @unchecked Sendable {
    static let shared = HiDPIService()
    private init() {}

    /// Ownership state of a display's plist override.
    enum OverrideState: Equatable {
        /// No HiDPI override is in effect (no file, or a file without `scale-resolutions`).
        case none
        /// Nunbit wrote the override (or merged into it) — the toggle may remove it again.
        case managedByNunbit
        /// The override exists but was not created by Nunbit (e.g. BetterDisplay).
        /// Nunbit never modifies or deletes it.
        case managedByOther
    }

    private var refreshTask: Task<Void, Never>?

    private let overridesBase = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")

    // MARK: - Public API

    /// Checks whether a HiDPI plist override is in effect for the given display.
    /// A file that exists but carries no `scale-resolutions` (another tool's metadata
    /// override, e.g. only `DisplayProductName`) does not count as HiDPI being enabled.
    func isHiDPIEnabled(for displayID: CGDirectDisplayID, vendor: UInt32, product: UInt32) -> Bool {
        isHiDPIEnabled(vendor: vendor, product: product)
    }

    /// Checks whether a HiDPI plist override is in effect for the given vendor/product.
    func isHiDPIEnabled(vendor: UInt32, product: UInt32) -> Bool {
        let plistURL = overridePlistURL(vendor: vendor, product: product)
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let dict = readOverridePlist(at: plistURL),
              let modes = dict["scale-resolutions"] as? [Data] else {
            return false
        }
        return !modes.isEmpty
    }

    /// Reports who owns the override currently in effect for this display, so the UI
    /// never claims (or deletes) another tool's override.
    func overrideState(vendor: UInt32, product: UInt32) -> OverrideState {
        guard isHiDPIEnabled(vendor: vendor, product: product) else { return .none }
        if ownershipRecord(vendor: vendor, product: product) != nil { return .managedByNunbit }
        // Overrides written before ownership bookkeeping existed are adopted only when
        // their contents are exactly what this service generates.
        if adoptLegacyOverrideIfPossible(vendor: vendor, product: product) != nil { return .managedByNunbit }
        return .managedByOther
    }

    /// Enables HiDPI for an external display via plist override.
    /// Requires display reconnect (or reboot) to apply.
    ///
    /// Returns nil on success, or an error string on failure.
    func enableHiDPI(for displayID: CGDirectDisplayID,
                     vendor: UInt32,
                     product: UInt32,
                     nativeWidth: Int,
                     nativeHeight: Int) async -> String? {
        await enableHiDPIPlist(vendor: vendor, product: product,
                               nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Legacy single-path enable (plist only).
    func enableHiDPI(vendor: UInt32, product: UInt32, nativeWidth: Int, nativeHeight: Int) async -> String? {
        await enableHiDPIPlist(vendor: vendor, product: product,
                               nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Disables HiDPI for an external display by removing the plist override.
    /// Only an override Nunbit itself wrote is removed.
    func disableHiDPI(for displayID: CGDirectDisplayID,
                      vendor: UInt32,
                      product: UInt32) async -> String? {
        await disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Legacy single-path disable (plist only).
    func disableHiDPI(vendor: UInt32, product: UInt32) async -> String? {
        await disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Refreshes availableModes on the given DisplayInfo after enabling HiDPI.
    func refreshModes(for display: DisplayInfo) {
        refreshTask?.cancel()
        let physicalID = display.displayID

        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            async let modes = Task.detached(priority: .userInitiated) {
                DisplayMode.availableModes(for: physicalID)
            }.value
            async let current = Task.detached(priority: .userInitiated) {
                DisplayMode.currentMode(for: physicalID)
            }.value
            display.availableModes = await modes
            display.currentDisplayMode = await current
        }
    }

    // MARK: - Plist Override

    private func enableHiDPIPlist(vendor: UInt32, product: UInt32,
                                  nativeWidth: Int, nativeHeight: Int) async -> String? {
        let dirPath = overrideDir(vendor: vendor).path
        let plistPath = overridePlistURL(vendor: vendor, product: product).path
        let plistURL = URL(fileURLWithPath: plistPath)
        let fileExisted = FileManager.default.fileExists(atPath: plistPath)

        // Merge into an existing override rather than replacing it. Another tool
        // (e.g. BetterDisplay) may keep its own keys and modes in the same file, and
        // `cp` over it would silently discard them.
        var existing: [String: Any] = [:]
        if fileExisted {
            guard let dict = readOverridePlist(at: plistURL) else {
                return "An override file already exists for this display but could not be read; refusing to overwrite it"
            }
            existing = dict
        }

        var existingModes: [Data] = []
        if let raw = existing["scale-resolutions"] {
            guard let modes = raw as? [Data] else {
                return "The existing override has an unexpected format; refusing to overwrite it"
            }
            existingModes = modes
        }

        let ourModes = generateScaledModes(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let knownEntries = Set(existingModes.map(hexString))
        let added = ourModes.filter { !knownEntries.contains(hexString($0)) }

        var merged = existing
        merged["scale-resolutions"] = existingModes + added

        if let err = await writeOverridePlist(merged, at: plistPath, dirPath: dirPath) {
            return err
        }

        // Record ownership so a later disable removes only Nunbit's own entries.
        let previous = ownershipRecord(vendor: vendor, product: product)
        let owned = Array(Set(previous?.ourEntries ?? []).union(added.map(hexString)))
        setOwnership(OverrideRecord(vendor: vendor, product: product,
                                    createdFile: (previous?.createdFile ?? false) || !fileExisted,
                                    ourEntries: owned),
                     vendor: vendor, product: product)

        // Attempt to trigger display mode re-enumeration via IOServiceRequestProbe
        triggerDisplayReenumeration(vendor: vendor, product: product)

        return nil
    }

    private func disableHiDPIPlist(vendor: UInt32, product: UInt32) async -> String? {
        let plistPath = overridePlistURL(vendor: vendor, product: product).path
        let plistURL = URL(fileURLWithPath: plistPath)
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }

        // Only ever remove an override this app wrote. Existence of a file is not
        // proof of ownership — another tool may have created it.
        guard let record = ownershipRecord(vendor: vendor, product: product)
                ?? adoptLegacyOverrideIfPossible(vendor: vendor, product: product) else {
            return "This display's HiDPI override was not created by Nunbit, so it was left untouched."
        }

        let dirPath = overrideDir(vendor: vendor).path

        if record.createdFile {
            if let err = await executePrivilegedCommand("rm -f '\(plistPath)'") {
                return err
            }
            setOwnership(nil, vendor: vendor, product: product)
            return nil
        }

        // Nunbit merged into a file that already existed: remove only our entries
        // and leave every other key and mode untouched.
        guard let dict = readOverridePlist(at: plistURL) else {
            return "The override file could not be read; it was left untouched."
        }

        let ours = Set(record.ourEntries)
        var updated = dict
        if var modes = dict["scale-resolutions"] as? [Data] {
            modes.removeAll { ours.contains(hexString($0)) }
            if modes.isEmpty {
                updated.removeValue(forKey: "scale-resolutions")
            } else {
                updated["scale-resolutions"] = modes
            }
        }

        if updated.isEmpty {
            // Nothing of the other tool's override is left — drop the file itself.
            if let err = await executePrivilegedCommand("rm -f '\(plistPath)'") {
                return err
            }
        } else if let err = await writeOverridePlist(updated, at: plistPath, dirPath: dirPath) {
            return err
        }

        setOwnership(nil, vendor: vendor, product: product)
        return nil
    }

    // MARK: - Privileged write

    /// Serializes `plist` and installs it at `path` with administrator privileges.
    /// Returns nil on success, or an error message on failure.
    private func writeOverridePlist(_ plist: [String: Any], at path: String, dirPath: String) async -> String? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return "Failed to generate plist data"
        }

        // Unique name: two displays can be enabled back to back without racing.
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fd_hidpi_override_\(UUID().uuidString).plist")
        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            return "Failed to write temporary file: \(error.localizedDescription)"
        }
        // Clean up on every exit path — including a failed command or a password
        // prompt the user cancels, which used to leave the temp file behind.
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        return await executePrivilegedCommand("mkdir -p '\(dirPath)' && cp '\(tmpURL.path)' '\(path)'")
    }

    // MARK: - Helpers

    /// Executes a shell command with administrator privileges via AppleScript.
    /// Returns nil on success, or an error message on failure.
    ///
    /// `NSAppleScript.executeAndReturnError` blocks until the authorization dialog is
    /// answered, so the whole thing runs off the main actor: executing it there froze
    /// the menu panel and stopped the row spinner from animating.
    private func executePrivilegedCommand(_ command: String) async -> String? {
        let script = """
            do shell script "\(command)" with administrator privileges
            """
        return await Task.detached(priority: .userInitiated) { () -> String? in
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                return "Failed to create AppleScript"
            }
            appleScript.executeAndReturnError(&error)
            if let error = error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                if msg.contains("canceled") || msg.contains("Cancel") {
                    return "Authorization was cancelled by the user"
                }
                return "Administrator authorization failed: \(msg)"
            }
            return nil
        }.value
    }

    private func triggerDisplayReenumeration(vendor: UInt32, product: UInt32) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let cfDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() else {
                continue
            }
            let dict = cfDict as NSDictionary

            let serviceVendor: UInt32
            let serviceProduct: UInt32

            if let v = dict["DisplayVendorID"] as? UInt32 {
                serviceVendor = v
            } else if let v = dict["DisplayVendorID"] as? Int {
                serviceVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let p = dict["DisplayProductID"] as? UInt32 {
                serviceProduct = p
            } else if let p = dict["DisplayProductID"] as? Int {
                serviceProduct = UInt32(bitPattern: Int32(truncatingIfNeeded: p))
            } else { continue }

            guard serviceVendor == vendor && serviceProduct == product else { continue }

            IOServiceRequestProbe(service, 0)
            break
        }
    }

    private func overrideDir(vendor: UInt32) -> URL {
        overridesBase
            .appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
    }

    private func overridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        overrideDir(vendor: vendor)
            .appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    // MARK: - Ownership bookkeeping

    /// One record per vendor/product pair Nunbit has written an override for.
    private struct OverrideRecord: Codable {
        var vendor: UInt32
        var product: UInt32
        /// True when Nunbit created the file (nothing existed before), so removing the
        /// file outright is the correct undo.
        var createdFile: Bool
        /// The `scale-resolutions` entries Nunbit added (hex encoded), so a merged file
        /// can be un-merged without touching another tool's entries.
        var ourEntries: [String]
    }

    private let ownershipURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Nunbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hidpi-overrides.json")
    }()

    private func ownershipKey(vendor: UInt32, product: UInt32) -> String {
        String(format: "%x-%x", vendor, product)
    }

    private func loadOwnership() -> [String: OverrideRecord] {
        guard let data = try? Data(contentsOf: ownershipURL),
              let records = try? JSONDecoder().decode([String: OverrideRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func setOwnership(_ record: OverrideRecord?, vendor: UInt32, product: UInt32) {
        var records = loadOwnership()
        let key = ownershipKey(vendor: vendor, product: product)
        if let record {
            records[key] = record
        } else {
            records.removeValue(forKey: key)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: ownershipURL, options: .atomic)
    }

    private func ownershipRecord(vendor: UInt32, product: UInt32) -> OverrideRecord? {
        loadOwnership()[ownershipKey(vendor: vendor, product: product)]
    }

    /// Recognizes an override written by a Nunbit build that predates ownership
    /// bookkeeping, so those users can still toggle it off.
    ///
    /// Deliberately strict: the file must contain nothing but our own generated mode
    /// set. Anything else (extra keys, extra modes) belongs to another tool.
    private func adoptLegacyOverrideIfPossible(vendor: UInt32, product: UInt32) -> OverrideRecord? {
        let url = overridePlistURL(vendor: vendor, product: product)
        guard let dict = readOverridePlist(at: url), dict.count == 1,
              let modes = dict["scale-resolutions"] as? [Data],
              let largest = modes.max(by: { backingPixelCount($0) < backingPixelCount($1) }),
              let (baseWidth, baseHeight) = logicalSize(fromBacking: largest) else {
            return nil
        }

        let expected = Set(generateScaledModes(nativeWidth: baseWidth, nativeHeight: baseHeight).map(hexString))
        guard !expected.isEmpty, Set(modes.map(hexString)) == expected else { return nil }

        let record = OverrideRecord(vendor: vendor, product: product,
                                    createdFile: true, ourEntries: Array(expected))
        setOwnership(record, vendor: vendor, product: product)
        return record
    }

    private func readOverridePlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Backing-store pixel count of an 8-byte big-endian (width, height) mode entry.
    private func backingPixelCount(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        guard bytes.count == 8 else { return 0 }
        let width = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let height = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        return width * height
    }

    /// A `scale-resolutions` entry stores the backing store size, i.e. 2× the logical
    /// resolution for a HiDPI mode.
    private func logicalSize(fromBacking data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count == 8 else { return nil }
        let width = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let height = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard width > 1, height > 1, width % 2 == 0, height % 2 == 0 else { return nil }
        return (width / 2, height / 2)
    }

    private func generateScaledModes(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        // Generate HiDPI modes: each entry is 8 bytes big-endian (backingW, backingH)
        // For a 2560×1440 display, we want:
        //   1920×1080 HiDPI (backing 3840×2160)
        //   1600×900  HiDPI (backing 3200×1800)
        //   1280×720  HiDPI (backing 2560×1440)
        //   native as HiDPI (backing 5120×2880)
        var resolutions: [(Int, Int)] = []

        // Native resolution as HiDPI (2x backing)
        resolutions.append((nativeWidth * 2, nativeHeight * 2))

        // Scaled HiDPI modes
        let scales: [Double] = [0.75, 0.625, 0.5]
        for scale in scales {
            let logicalW = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let logicalH = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard logicalW >= 800, logicalH >= 600 else { continue }
            resolutions.append((logicalW * 2, logicalH * 2))
        }

        return resolutions.map { (backingW, backingH) in
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes[0] = UInt8((backingW >> 24) & 0xFF)
            bytes[1] = UInt8((backingW >> 16) & 0xFF)
            bytes[2] = UInt8((backingW >> 8) & 0xFF)
            bytes[3] = UInt8(backingW & 0xFF)
            bytes[4] = UInt8((backingH >> 24) & 0xFF)
            bytes[5] = UInt8((backingH >> 16) & 0xFF)
            bytes[6] = UInt8((backingH >> 8) & 0xFF)
            bytes[7] = UInt8(backingH & 0xFF)
            return Data(bytes)
        }
    }
}
