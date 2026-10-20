import AppKit
import CoreGraphics
import Foundation

/// One-click "headless" session for an idle game.
///
/// The session makes a virtual display the main display and holds a sleep
/// assertion, so the game window on the virtual display keeps rendering while the
/// physical monitor is switched off. No virtual-display DRM tricks are involved:
/// this is only for games/apps that do not require HDCP.
@MainActor
final class HeadlessSessionService: ObservableObject {
    static let shared = HeadlessSessionService()

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var activeConfigID: UUID?
    @Published private(set) var errorMessage: String?

    /// Main display before the session started, so Stop can restore it.
    private var previousMainDisplayID: CGDirectDisplayID?
    /// True once the pre-session main display has gone offline (monitor powered off).
    private var physicalWasOffline = false
    /// True when this session created the virtual display (vs. reusing an active one).
    private var createdDisplayForSession = false

    private var reassertTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleMainReassert()
            }
        }
    }

    // MARK: - Session lifecycle

    @discardableResult
    func start(configID: UUID) async -> Bool {
        guard !isRunning, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }

        errorMessage = nil

        let virtualDisplays = VirtualDisplayService.shared
        guard let config = virtualDisplays.configs.first(where: { $0.id == configID }) else {
            errorMessage = "找不到虚拟显示器配置"
            return false
        }

        // Capture this before creating the virtual display: on a headless Mac the
        // newly created display could otherwise become main and be recorded as
        // the display we should restore.
        let previousMain = CGMainDisplayID()

        let wasOnline = virtualDisplays.isOnline(configID)
        if !wasOnline {
            guard await virtualDisplays.create(config: config) else {
                errorMessage = "虚拟显示器创建失败"
                return false
            }
        }

        guard let virtualID = virtualDisplays.displayID(for: configID),
              virtualDisplays.isOnline(configID) else {
            if !wasOnline { _ = virtualDisplays.destroy(configID: configID) }
            errorMessage = "虚拟显示器未上线"
            return false
        }

        previousMainDisplayID = previousMain
        physicalWasOffline = false
        createdDisplayForSession = !wasOnline
        activeConfigID = configID

        guard await ArrangementService.shared.setAsMainDisplay(virtualID) else {
            // WindowServer can briefly reject a transaction right after a display
            // appears; one retry is enough to ride out the transition.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard await ArrangementService.shared.setAsMainDisplay(virtualID) else {
                await rollbackStart(configID: configID)
                errorMessage = "无法把虚拟显示器设为主屏"
                return false
            }
            return await finishStart(configID: configID)
        }

        return await finishStart(configID: configID)
    }

    private func finishStart(configID: UUID) async -> Bool {
        guard SleepAssertionService.shared.acquire(
            .headlessSession,
            reason: "FreeDisplay headless session"
        ) else {
            await rollbackStart(configID: configID)
            errorMessage = "无法阻止系统睡眠"
            return false
        }

        isRunning = true
        return true
    }

    func stop() async {
        guard isRunning, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        reassertTask?.cancel()
        reassertTask = nil
        SleepAssertionService.shared.release(.headlessSession)

        let configID = activeConfigID
        let shouldDestroy = createdDisplayForSession

        await restorePreviousMain()

        if shouldDestroy, let configID {
            _ = VirtualDisplayService.shared.destroy(configID: configID)
        }

        isRunning = false
        activeConfigID = nil
        previousMainDisplayID = nil
        physicalWasOffline = false
        createdDisplayForSession = false
        errorMessage = nil
    }

    private func rollbackStart(configID: UUID) async {
        SleepAssertionService.shared.release(.headlessSession)
        await restorePreviousMain()
        if createdDisplayForSession {
            _ = VirtualDisplayService.shared.destroy(configID: configID)
        }
        isRunning = false
        activeConfigID = nil
        previousMainDisplayID = nil
        physicalWasOffline = false
        createdDisplayForSession = false
    }

    private func restorePreviousMain() async {
        guard let previous = previousMainDisplayID,
              CGDisplayIsOnline(previous) != 0 else { return }
        _ = await ArrangementService.shared.setAsMainDisplay(previous)
    }

    // MARK: - Display changes

    /// A monitor power cycle or wake can make macOS choose a different main display.
    /// While the session is running, keep the virtual display main.
    private func scheduleMainReassert() {
        guard isRunning else { return }
        reassertTask?.cancel()
        reassertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.ensureVirtualDisplayIsMain()
        }
    }

    private func ensureVirtualDisplayIsMain() async {
        guard isRunning, let configID = activeConfigID else { return }

        // When the physical monitor comes back after being switched off, restore it
        // as the main display. The session and the game keep running on the virtual
        // display, but the user can reach the menu bar again to stop the session.
        if let previous = previousMainDisplayID {
            if CGDisplayIsOnline(previous) == 0 {
                physicalWasOffline = true
            } else if physicalWasOffline {
                physicalWasOffline = false
                _ = await ArrangementService.shared.setAsMainDisplay(previous)
                return
            }
        }

        let virtualDisplays = VirtualDisplayService.shared
        if !virtualDisplays.isOnline(configID) {
            guard let config = virtualDisplays.configs.first(where: { $0.id == configID }) else {
                return
            }
            guard await virtualDisplays.create(config: config) else { return }
        }

        guard let virtualID = virtualDisplays.displayID(for: configID),
              virtualDisplays.isOnline(configID) else { return }

        if CGDisplayIsMain(virtualID) == 0 {
            _ = await ArrangementService.shared.setAsMainDisplay(virtualID)
        }
    }
}
