import SwiftUI

// MARK: - Shared Icon Helper

/// A colored rounded-square SF Symbol icon, consistent with macOS Settings style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(label).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? "\(label), expanded" : "\(label), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
        .help("Click to expand or collapse this section")
    }
}

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showAutoBrightness: Bool = false
    @State private var showLectureMode: Bool = false
    @State private var showHeadlessSession: Bool = false
    @State private var showSettings: Bool = false
    @State private var quitHovered = false

    /// All online displays, including Nunbit's virtual displays.
    /// Virtual displays are shown so the user can change their mode or promote one
    /// to the main display; they used to be hidden, which made a one-physical +
    /// one-virtual setup impossible to control from the menu.
    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Display list
                ForEach(visibleDisplays) { display in
                    VStack(spacing: 0) {
                        DisplayRowView(
                            display: display,
                            isExpanded: expandedDisplayIDs.contains(display.displayID),
                            onToggleExpand: {
                                if expandedDisplayIDs.contains(display.displayID) {
                                    expandedDisplayIDs.remove(display.displayID)
                                } else {
                                    expandedDisplayIDs.insert(display.displayID)
                                }
                            }
                        )

                        if expandedDisplayIDs.contains(display.displayID) {
                            DisplayDetailView(display: display)
                        }
                    }
                }

                // Preset list (Phase 19)
                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                PresetListView()

                // Arrange Displays section (Phase 4)
                if visibleDisplays.count > 1 {
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)

                    ExpandableRow(
                        icon: "rectangle.3.offgrid",
                        iconColor: .blue,
                        label: "Arrange Displays",
                        isExpanded: $showArrangement
                    )

                    if showArrangement {
                        ArrangementView()
                            .environmentObject(displayManager)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Combined brightness control (Phase 2)
                if settings.showCombinedBrightness {
                    CombinedBrightnessView(displays: displayManager.displays.filter {
                        !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
                    })
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)
                }

                // Tools section header
                Text("Tools")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                // Virtual Display tools entry (Phase 10)
                ExpandableRow(
                    icon: "display.2",
                    iconColor: .blue,
                    label: "Virtual Display",
                    isExpanded: $showVirtualDisplays
                )

                if showVirtualDisplays {
                    VirtualDisplayView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Auto Brightness entry (Phase 11)
                ExpandableRow(
                    icon: "sun.and.horizon.fill",
                    iconColor: .orange,
                    label: "Auto Brightness",
                    isExpanded: $showAutoBrightness
                )

                if showAutoBrightness {
                    AutoBrightnessView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Lecture Mode (personal branch): prevents sleep only, no virtual display
                ExpandableRow(
                    icon: "play.rectangle.fill",
                    iconColor: .green,
                    label: "Lecture Mode",
                    isExpanded: $showLectureMode
                )

                if showLectureMode {
                    LectureModeView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Headless Session (personal branch): virtual display as main + sleep prevention
                ExpandableRow(
                    icon: "moon.stars.fill",
                    iconColor: .indigo,
                    label: "Headless Session",
                    isExpanded: $showHeadlessSession
                )

                if showHeadlessSession {
                    HeadlessSessionView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Settings section (Phase 12)
                ExpandableRow(
                    icon: "gearshape.fill",
                    iconColor: .gray,
                    label: "Settings",
                    isExpanded: $showSettings
                )

                if showSettings {
                    SettingsView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Update notice (Phase 12)
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("Version v\(ver) available")
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button("View") { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help("Download and install the latest version")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

            }
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 60, maxHeight: 640)

        Divider().opacity(0.3)

        // Version and quit (fixed at the bottom, does not scroll with content)
        HStack {
            Text("Nunbit v\(updateService.currentVersion)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text("Quit")
                }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(quitHovered ? .red : .secondary)
            .onHover { quitHovered = $0 }
            .help("Quit Nunbit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @EnvironmentObject private var displayManager: DisplayManager
    @AppStorage("fd.arrangement.externalAbove") private var externalAboveBuiltin = false
    @AppStorage(DisplayManager.autoEnableHiDPIKey) private var autoEnableHiDPI = false
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Launch at login
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    // Register/unregister, then show the state the system actually reports:
                    // registration can fail (app not in /Applications, approval pending).
                    launchAtLoginError = LaunchService.shared.setEnabled(newValue)
                    settings.launchAtLogin = LaunchService.shared.isEnabled
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text("Launch at Login")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Launch Nunbit automatically when you log in")

            // Registration failure — the switch above stays off in that case.
            if let launchAtLoginError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .accessibilityHidden(true)
                    Text(launchAtLoginError)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // First-launch prompt: suggest enabling launch at login
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Launch at Login recommended")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Got it") {
                        settings.launchAtLoginPrompted = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .onAppear {
                    // Mark as prompted so it only shows once
                    // User dismisses manually via the "Got it" button
                }
            }

            // Show combined brightness
            Toggle(isOn: $settings.showCombinedBrightness) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.min.fill", color: .yellow)
                        .accessibilityHidden(true)
                    Text("Show Combined Brightness Control")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Show a unified brightness slider for all displays in the menu bar")

            // Automatically arrange external displays above the built-in display (off by default)
            Toggle(isOn: $externalAboveBuiltin) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "rectangle.3.offgrid", color: .blue)
                        .accessibilityHidden(true)
                    Text("Auto-arrange External Displays")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Center external displays above the built-in display; usually not needed with a single display or a Mac mini")

            // Automatically enable HiDPI for newly connected 2K+ displays (off by default:
            // it writes a privileged override file and requires a reconnect)
            Toggle(isOn: $autoEnableHiDPI) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sparkles.rectangle.stack", color: .blue)
                        .accessibilityHidden(true)
                    Text("Enable HiDPI Automatically")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Off by default. When a 2K+ display is connected, asks for administrator approval once and writes a display override file into /Library/Displays. The display must be reconnected for it to take effect.")

            // Check for updates at launch
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text("Check for Updates at Launch")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Automatically check for a new version on every launch")
        }
        .padding(.vertical, 6)
        .onChange(of: externalAboveBuiltin) { _, enabled in
            if enabled {
                displayManager.arrangeExternalAboveBuiltin()
            }
        }
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var isHovered: Bool = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                    .rotationEffect(Angle(degrees: isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .accessibilityHidden(true)

                MenuItemIcon(systemName: display.isBuiltin ? "laptopcomputer" : "display", color: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let mode = display.currentDisplayMode {
                        Text(mode.resolutionString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if display.isMain {
                    Text("Main")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(3)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            .help("Expand display controls")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in System Settings", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Copy Display Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Click to expand the control panel")
        .accessibilityAddTraits(.isButton)
    }
}
