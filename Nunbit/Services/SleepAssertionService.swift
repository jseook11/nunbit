import Foundation
import IOKit.pwr_mgt

/// Prevents idle system and/or display sleep while at least one owner holds an
/// assertion. This is the native equivalent of `caffeinate -di`: unlike a child
/// `caffeinate` process, IOPM assertions are released automatically by the kernel
/// when the app exits or crashes, so a failure cannot leave the Mac awake forever.
@MainActor
final class SleepAssertionService: ObservableObject {
    static let shared = SleepAssertionService()

    /// Reason strings registered with IOPM. They show up in `pmset -g assertions`.
    enum Owner: String, CaseIterable {
        case lecture
        case headlessSession
    }

    @Published private(set) var activeOwners: Set<Owner> = []

    private var systemOwners: Set<Owner> = []
    private var displayOwners: Set<Owner> = []

    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var lastReason = "Nunbit"

    private init() {}

    var isActive: Bool { !activeOwners.isEmpty }

    func isHeld(by owner: Owner) -> Bool {
        activeOwners.contains(owner)
    }

    /// Adds `owner` to the assertion set.
    ///
    /// - Parameter preventDisplaySleep: `false` allows the display to sleep while
    ///   keeping the system awake (lecture playback). `true` keeps both the system
    ///   and the display awake (virtual display / idle game).
    /// - Returns: false when the required assertions could not be created.
    @discardableResult
    func acquire(
        _ owner: Owner,
        reason: String,
        preventDisplaySleep: Bool = true
    ) -> Bool {
        if activeOwners.contains(owner) { return true }

        lastReason = reason
        systemOwners.insert(owner)
        if preventDisplaySleep {
            displayOwners.insert(owner)
        }
        ensureAssertions()

        let systemOK = systemAssertionID != 0
        let displayOK = !preventDisplaySleep || displayAssertionID != 0
        guard systemOK && displayOK else {
            // Roll back this owner; other owners may still hold their assertions.
            systemOwners.remove(owner)
            displayOwners.remove(owner)
            releaseUnusedAssertions()
            return false
        }

        activeOwners.insert(owner)
        return true
    }

    func release(_ owner: Owner) {
        systemOwners.remove(owner)
        displayOwners.remove(owner)
        activeOwners.remove(owner)
        releaseUnusedAssertions()
    }

    func setHeld(
        _ held: Bool,
        by owner: Owner,
        reason: String,
        preventDisplaySleep: Bool = true
    ) {
        if held {
            _ = acquire(owner, reason: reason, preventDisplaySleep: preventDisplaySleep)
        } else {
            release(owner)
        }
    }

    /// Called on app termination. The kernel releases assertions on exit anyway,
    /// but doing it explicitly keeps `pmset -g assertions` clean during shutdown.
    func stopAll() {
        systemOwners.removeAll()
        displayOwners.removeAll()
        activeOwners.removeAll()
        releaseUnusedAssertions()
    }

    private func ensureAssertions() {
        if !systemOwners.isEmpty, systemAssertionID == 0 {
            systemAssertionID = Self.createAssertion(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                reason: lastReason
            )
        }
        if !displayOwners.isEmpty, displayAssertionID == 0 {
            displayAssertionID = Self.createAssertion(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                reason: lastReason
            )
        }
    }

    private func releaseUnusedAssertions() {
        if systemOwners.isEmpty, systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayOwners.isEmpty, displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }

    private static func createAssertion(type: String, reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : 0
    }
}
