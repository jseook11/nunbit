import Foundation
import CoreGraphics
@preconcurrency import ColorSync

/// ICC color profile model.
struct ICCProfile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: URL
    let colorSpaceType: String  // "RGB", "CMYK", "Gray", etc.

    init(name: String, path: URL, colorSpaceType: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.colorSpaceType = colorSpaceType
    }

    /// Convenience failable initializer: loads profile metadata from a file URL.
    init?(url: URL) {
        guard let profile = ColorProfileService.makeProfile(from: url) else { return nil }
        self = profile
    }

    static func == (lhs: ICCProfile, rhs: ICCProfile) -> Bool {
        lhs.path == rhs.path
    }
}

/// Service for ICC color profile enumeration and switching.
/// Uses ColorSync framework + file system scanning.
final class ColorProfileService: @unchecked Sendable {
    static let shared = ColorProfileService()
    private init() {}

    // MARK: - Profile Enumeration

    /// The profiles applicable to one display, plus the URL of its active profile.
    struct ProfileCatalog {
        let profiles: [ICCProfile]
        let currentURL: URL?
    }

    /// Returns the installed ICC profiles that apply to `displayID`, sorted alphabetically.
    ///
    /// macOS writes one `<DisplayName>-<DisplayUUID>.icc` per display it has ever seen —
    /// old monitors, Sidecar sessions, virtual displays and an all-zero generic copy — and
    /// every file carries the same human-readable description. Listing the whole folder
    /// made the picker look full of duplicates. Keep only this display's own file, the
    /// currently active profile (whatever its UUID) and the generic profiles that live
    /// outside the per-display `Displays` folders.
    func enumerateProfiles(for displayID: CGDirectDisplayID) async -> ProfileCatalog {
        // Everything here is IPC/file I/O (ColorSync device info, a recursive scan and ICC
        // header parsing), so it all runs off the main actor.
        let result: (profiles: [ICCProfile], currentURL: URL?, displayUUID: String?) =
            await Task.detached(priority: .userInitiated) {
            let currentURL = self.currentProfileURL(for: displayID)
            let displayUUID = Self.displayUUIDString(for: displayID)
            var profiles: [ICCProfile] = []
            let searchURLs: [URL] = [
                URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/ColorSync/Profiles")
            ]

            var seenPaths = Set<URL>()
            let fm = FileManager.default

            for dir in searchURLs {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let url = enumerator.nextObject() as? URL {
                    guard !seenPaths.contains(url) else { continue }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "icc" || ext == "icm" else { continue }
                    // Only monitor-class, RGB profiles are safe to feed to
                    // ColorSyncDeviceSetCustomProfiles. CMYK/printer/abstract profiles
                    // can abort inside SkyLight/WindowServer.
                    guard Self.isDisplayRGBProfile(at: url) else { continue }
                    seenPaths.insert(url)
                    if let profile = Self.makeProfileImpl(from: url) {
                        profiles.append(profile)
                    }
                }
            }

            let sorted = profiles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return (sorted, currentURL, displayUUID)
        }.value

        let relevant = result.profiles.filter {
            Self.isProfileRelevant($0.path, displayUUID: result.displayUUID, activeURL: result.currentURL)
        }
        return ProfileCatalog(profiles: relevant, currentURL: result.currentURL)
    }

    // MARK: - Display-specific filtering

    /// UUID string of a CGDirectDisplayID, matching the suffix macOS uses on display
    /// profile filenames (`Color LCD-37D8832A-2D66-02CA-B9F7-8F30A301B230.icc`).
    static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = rawUUID.takeRetainedValue()
        guard let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return (string as String).uppercased()
    }

    /// Extracts the trailing display UUID from a profile filename, if present.
    private static func uuidFromProfileFileName(_ fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        guard base.count >= 37 else { return nil }
        let uuid = String(base.suffix(36))
        guard base[base.index(base.endIndex, offsetBy: -37)] == "-" else { return nil }
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        guard uuid.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return uuid.uppercased()
    }

    /// A profile is shown for a display when it is generic, when it belongs to this
    /// display's UUID, or when it is the profile that is actually active right now.
    private static func isProfileRelevant(
        _ url: URL,
        displayUUID: String?,
        activeURL: URL?
    ) -> Bool {
        guard url.path.contains("/ColorSync/Profiles/Displays/") else { return true }
        if let activeURL,
           url.standardizedFileURL == activeURL.standardizedFileURL {
            return true
        }
        guard let profileUUID = uuidFromProfileFileName(url.lastPathComponent),
              let displayUUID else { return true }
        return profileUUID == displayUUID
    }

    static func makeProfile(from url: URL) -> ICCProfile? {
        makeProfileImpl(from: url)
    }

    private static func makeProfileImpl(from url: URL) -> ICCProfile? {
        let name: String
        let csType: String

        if let rawProfile = ColorSyncProfileCreateWithURL(url as CFURL, nil) {
            let profile = rawProfile.takeRetainedValue()
            if let rawDesc = ColorSyncProfileCopyDescriptionString(profile) {
                name = rawDesc.takeRetainedValue() as String
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }
            csType = colorSpaceType(from: profile)
        } else {
            name = url.deletingPathExtension().lastPathComponent
            csType = "RGB"
        }

        return ICCProfile(name: name, path: url, colorSpaceType: csType)
    }

    /// Validates the ICC header before a profile is listed or applied.
    /// Only monitor-class (`mntr`) profiles with an RGB data color space are safe for
    /// `ColorSyncDeviceSetCustomProfiles`; printer/CMYK/abstract profiles can abort
    /// inside SkyLight/WindowServer.
    static func isDisplayRGBProfile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 128), header.count >= 128 else {
            return false
        }
        // ICC header: device class at bytes 12..<16, data color space at 16..<20.
        guard let deviceClass = String(data: header[12..<16], encoding: .ascii),
              let colorSpace = String(data: header[16..<20], encoding: .ascii) else {
            return false
        }
        return deviceClass == "mntr" && colorSpace == "RGB "
    }

    private static func colorSpaceType(from profile: ColorSyncProfile) -> String {
        guard let rawData = ColorSyncProfileCopyHeader(profile) else { return "RGB" }
        let data = rawData.takeRetainedValue() as Data
        // ICC header: data color space at byte offset 16, 4 bytes (ASCII-encoded tag).
        guard data.count >= 20 else { return "RGB" }
        let bytes = [UInt8](data[16..<20])
        // Validate that all bytes are printable ASCII (0x20–0x7E) before decoding.
        // Non-ASCII bytes indicate a corrupt or non-standard header; fall back to "RGB".
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
              let str = String(bytes: bytes, encoding: .ascii) else { return "RGB" }
        switch str.trimmingCharacters(in: .whitespaces) {
        case "RGB":  return "RGB"
        case "CMYK": return "CMYK"
        case "GRAY": return "Gray"
        case "LAB":  return "Lab"
        case "XYZ":  return "XYZ"
        default:     return "RGB"
        }
    }

    // MARK: - Current Color Info

    /// Returns the human-readable name of the display's active color profile.
    ///
    /// Prefer the profile itself: `CGColorSpace.name` is nil for every ICC-based space
    /// (which is what `CGDisplayCopyColorSpace` returns for a panel running its factory
    /// profile), so relying on it alone showed "Unknown" for the built-in "Color LCD".
    func currentColorSpaceName(for displayID: CGDirectDisplayID) -> String {
        if let url = currentProfileURL(for: displayID),
           let profile = Self.makeProfile(from: url) {
            return profile.name
        }

        let colorSpace = CGDisplayCopyColorSpace(displayID)
        if let cfName = colorSpace.name {
            return humanReadable(cfName as String)
        }

        // Last resort: the description ends with the profile name, e.g.
        // "(kCGColorSpaceICCBased; kCGColorSpaceModelRGB; Color LCD)".
        let description = String(describing: colorSpace)
        if let tail = description.split(separator: ";").last {
            let name = tail.trimmingCharacters(in: CharacterSet(charactersIn: " )"))
            if !name.isEmpty { return name }
        }
        return "Unknown"
    }

    /// Returns a description like "Internal (8-bit)" for the display's current color mode.
    func colorModeDescription(for displayID: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "Unknown" }
        let encoding: String
        if let cfEnc = mode.pixelEncoding { encoding = cfEnc as String } else { encoding = "" }
        let bpc = bitsPerChannel(from: encoding)
        let source = CGDisplayIsBuiltin(displayID) != 0 ? "Internal" : "External"
        return "\(source) (\(bpc)-bit)"
    }

    private func bitsPerChannel(from encoding: String) -> Int {
        let rCount = encoding.filter { $0 == "R" }.count
        if rCount > 0 { return rCount }
        let dCount = encoding.filter { $0 == "D" }.count
        return dCount >= 30 ? 10 : 8
    }

    // Bridge CGColorSpace CFString constants to Swift String for comparison
    private func humanReadable(_ name: String) -> String {
        if name == (CGColorSpace.displayP3 as String)           { return "Display P3" }
        if name == (CGColorSpace.sRGB as String)                { return "sRGB IEC61966-2.1" }
        if name == (CGColorSpace.adobeRGB1998 as String)        { return "Adobe RGB (1998)" }
        if name == (CGColorSpace.genericRGBLinear as String)    { return "Generic RGB Linear" }
        if name == (CGColorSpace.extendedSRGB as String)        { return "Extended sRGB" }
        if name == (CGColorSpace.linearSRGB as String)          { return "Linear sRGB" }
        if name == (CGColorSpace.extendedLinearSRGB as String)  { return "Extended Linear sRGB" }
        if name == (CGColorSpace.genericGrayGamma2_2 as String) { return "Generic Gray Gamma 2.2" }
        if name.hasPrefix("kCGColorSpace") {
            return String(name.dropFirst("kCGColorSpace".count))
        }
        return name
    }

    // MARK: - Current Profile URL

    /// Returns the file URL of the currently active ICC profile for the given display, if available.
    func currentProfileURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = rawUUID.takeRetainedValue()

        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return nil }

        guard let rawInfo = ColorSyncDeviceCopyDeviceInfo(deviceClass, uuid) else { return nil }
        let info = rawInfo.takeRetainedValue() as NSDictionary

        // Determine the active mode name from FactoryProfiles[DeviceDefaultProfileID].
        // Both CustomProfiles and FactoryProfiles use this mode name as their key.
        let factoryProfiles = info["FactoryProfiles"] as? NSDictionary
        let activeModeName = factoryProfiles?[profileIDKey] as? String

        // CustomProfiles: keys are mode names, values are NSURL directly.
        if let modeName = activeModeName,
           let customProfiles = info["CustomProfiles"] as? NSDictionary,
           let url = customProfiles[modeName] as? NSURL {
            return url as URL
        }

        // Fall back to FactoryProfiles: the mode entry is a dict with a DeviceProfileURL.
        // On macOS 26 the value is an NSURL, not a String (older systems used a path
        // string), so handle both — otherwise the active profile resolves to nil and the
        // UI cannot highlight it.
        if let modeName = activeModeName,
           let modeDict = factoryProfiles?[modeName] as? NSDictionary,
           let urlValue = modeDict["DeviceProfileURL"] {
            if let url = urlValue as? NSURL {
                return url as URL
            }
            if let urlString = urlValue as? String {
                return urlString.hasPrefix("file:")
                    ? URL(string: urlString)
                    : URL(fileURLWithPath: urlString)
            }
        }

        return nil
    }

    // MARK: - Profile Switching

    /// Sets the ICC profile for the given display using ColorSync.
    /// Returns true on success.
    @discardableResult
    func setProfile(_ profile: ICCProfile, for displayID: CGDirectDisplayID) -> Bool {
        // Never hand a non-monitor / non-RGB profile to ColorSync.
        guard Self.isDisplayRGBProfile(at: profile.path) else { return false }
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return false }
        let uuid = rawUUID.takeRetainedValue()

        // kColorSyncDisplayDeviceClass and kColorSyncDeviceDefaultProfileID are
        // Unmanaged<CFString>? in the current SDK; use takeUnretainedValue() to borrow them.
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }

        let profileInfo: NSDictionary = [profileIDKey: profile.path as NSURL]

        return ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }

    /// Restores the display's factory/default profile via `kCFNull`.
    @discardableResult
    func resetProfile(for displayID: CGDirectDisplayID) -> Bool {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return false }
        let uuid = rawUUID.takeRetainedValue()
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }

        let profileInfo: NSDictionary = [profileIDKey: kCFNull as Any]
        return ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }
}
