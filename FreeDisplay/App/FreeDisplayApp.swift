import SwiftUI

@main
struct FreeDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var displayManager = DisplayManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(displayManager)
                .task {
                    // MenuBarExtra content is built lazily: this .task runs every time
                    // the panel opens. Never run one-shot launch/arrangement work here
                    // without a guard.
                    displayManager.scheduleInitialArrangeOnce()

                    // Wire up the wake-from-sleep handler so AppDelegate can call back
                    // into the live DisplayManager instance.
                    appDelegate.onWake = { [weak displayManager] in
                        guard let dm = displayManager else { return }
                        Task { @MainActor in
                            // Give WindowServer 2 seconds to stabilize after wake before
                            // touching display state.
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            dm.refreshDisplays()
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            for display in dm.displays {
                                // Apply software brightness factor first so GammaService
                                // can read the up-to-date factor when it re-applies its formula.
                                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                                GammaService.shared.reapplyIfNeeded(for: display.displayID)
                                // Re-apply any custom resolution that macOS may have reset on wake
                                ResolutionService.shared.reapplySavedModeIfNeeded(for: display.displayID)
                            }
                        }
                    }
                }
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
