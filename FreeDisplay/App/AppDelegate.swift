import AppKit
import CoreGraphics

class AppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?

    /// Called by FreeDisplayApp to provide access to the live DisplayManager instance.
    var onWake: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 防止重复启动：如果已有实例在运行，直接退出
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if runningApps.count > 1 {
            print("[FreeDisplay] Another instance is already running, exiting.")
            NSApp.terminate(nil)
            return
        }

        // Start intercepting brightness keys to route them to the display under the cursor.
        BrightnessKeyService.shared.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onWake?()
            }
            Task { @MainActor in
                // WindowServer can drop virtual displays across a system wake.
                await VirtualDisplayService.shared.reconcileActiveDisplays()
            }
        }

        screensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await VirtualDisplayService.shared.reconcileActiveDisplays()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = screensWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        BrightnessKeyService.shared.stop()
        // GammaService already handles CGDisplayRestoreColorSyncSettings via willTerminateNotification observer.
        VirtualDisplayService.shared.destroyAll()
    }
}
