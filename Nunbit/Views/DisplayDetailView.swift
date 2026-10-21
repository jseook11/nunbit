import SwiftUI

// MARK: - DisplayDetailView

struct DisplayDetailView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var showModeList: Bool = false
    @State private var showColorProfile: Bool = false
    @State private var showImageAdjustment: Bool = false
    @State private var colorSpaceName: String = ""

    private func sectionKey(_ name: String) -> String {
        "fd.expanded.\(display.displayUUID).\(name)"
    }

    private func loadExpanded(_ name: String, default value: Bool) -> Bool {
        let key = sectionKey(name)
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func saveExpanded(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: sectionKey(name))
    }

    /// Virtual displays control HiDPI through CGVirtualDisplaySettings. The plist
    /// override path is meaningless for them and can trigger an admin prompt.
    private var isVirtual: Bool {
        VirtualDisplayService.shared.isVirtualDisplay(display.displayID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Brightness slider — virtual displays have no backlight, so a brightness
            // value for them is meaningless (and DDC/gamma writes would target nothing).
            if !isVirtual {
                BrightnessSliderView(display: display)
            }

            if !isVirtual {
                Divider().opacity(0.3).padding(.vertical, 2)

                // HiDPI toggle — before mode list (natural workflow: enable HiDPI → pick resolution)
                HiDPIRowView(display: display)
            }

            // Display mode list toggle row
            ExpandableRow(
                icon: "rectangle.on.rectangle",
                label: "Display Mode",
                subtitle: {
                    var parts: [String] = []
                    if let mode = display.currentDisplayMode {
                        parts.append(mode.resolutionString)
                    }
                    if display.currentDisplayMode?.isHiDPI == true {
                        parts.append("HiDPI")
                    }
                    return parts.joined(separator: " · ")
                }(),
                isExpanded: $showModeList
            )

            if showModeList {
                DisplayModeListView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // Color profile section
            ExpandableRow(
                icon: "paintpalette.fill",
                iconColor: .purple,
                label: "Color Profile",
                subtitle: colorSpaceName,
                isExpanded: $showColorProfile
            )

            if showColorProfile {
                ColorProfileView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            // Image adjustment section
            ExpandableRow(
                icon: "slider.horizontal.3",
                label: "Image Adjustment",
                isExpanded: $showImageAdjustment
            )

            if showImageAdjustment {
                ImageAdjustmentView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // Set as main display
            MainDisplayView(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

        }
        .padding(.leading, 32)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .onAppear {
            showModeList = loadExpanded("modeList", default: false)
            showColorProfile = loadExpanded("colorProfile", default: false)
            showImageAdjustment = loadExpanded("imageAdjust", default: false)
        }
        .onChange(of: showModeList) { _, v in saveExpanded("modeList", v) }
        .onChange(of: showColorProfile) { _, v in
            saveExpanded("colorProfile", v)
            // Re-read on open: the active profile may have changed while it was closed.
            if v { refreshColorSpaceName() }
        }
        .onChange(of: showImageAdjustment) { _, v in saveExpanded("imageAdjust", v) }
        .task(id: display.displayID) {
            colorSpaceName = ""
            await readColorSpaceName()
        }
    }

    /// ColorSync device lookup + ICC parsing is IPC/file I/O; keep it off the main thread.
    private func refreshColorSpaceName() {
        Task { await readColorSpaceName() }
    }

    @MainActor
    private func readColorSpaceName() async {
        let id = display.displayID
        let name = await Task.detached(priority: .userInitiated) {
            ColorProfileService.shared.currentColorSpaceName(for: id)
        }.value
        guard !Task.isCancelled else { return }
        colorSpaceName = name
    }
}

