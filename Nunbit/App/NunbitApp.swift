import SwiftUI

@main
struct NunbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var displayManager = DisplayManager()

    var body: some Scene {
        // Read the state object here, in the app body, so SwiftUI instantiates it at
        // launch. The menu content below is built lazily, and DisplayManager installs
        // the wake-recovery observer in its initializer — that must happen on a login
        // launch even when the user never opens the menu.
        let _ = displayManager

        MenuBarExtra {
            MenuBarView()
                .environmentObject(displayManager)
                .task {
                    // MenuBarExtra content is built lazily: this .task runs every time
                    // the panel opens. Never run one-shot launch/arrangement work here
                    // without a guard.
                    displayManager.scheduleInitialArrangeOnce()
                    // Wake recovery is not wired up here on purpose: DisplayManager
                    // observes didWakeNotification itself, so it works even when the
                    // user never opens the menu.
                }
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
