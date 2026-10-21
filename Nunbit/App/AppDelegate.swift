import AppKit
import CoreGraphics

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var wakeObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate launches: if another instance is already running, exit immediately
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if runningApps.count > 1 {
            print("[Nunbit] Another instance is already running, exiting.")
            NSApp.terminate(nil)
            return
        }

        // Start intercepting brightness keys to route them to the display under the cursor.
        BrightnessKeyService.shared.start()

        // Display-state recovery (displays, software brightness, gamma, saved mode) is
        // owned by DisplayManager, which observes didWakeNotification itself. Wiring it
        // up from here via a closure assigned by the SwiftUI menu content meant it never
        // ran on a login launch where the menu was never opened.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
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
        SleepAssertionService.shared.stopAll()
        // GammaService already handles CGDisplayRestoreColorSyncSettings via willTerminateNotification observer.
        VirtualDisplayService.shared.destroyAll()
    }
}
