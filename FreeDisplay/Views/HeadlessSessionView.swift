import SwiftUI
import CoreGraphics

/// One-click session for an idle game: make a virtual display main, keep the Mac
/// awake, and let the user power off the physical monitor while the game keeps
/// rendering on the virtual display.
struct HeadlessSessionView: View {
    @ObservedObject private var virtualDisplays = VirtualDisplayService.shared
    @ObservedObject private var session = HeadlessSessionService.shared
    @AppStorage("fd.headless.configID") private var selectedConfigID: String = ""

    private var selectedUUID: UUID? {
        UUID(uuidString: selectedConfigID)
    }

    private var selectedConfig: VirtualDisplayService.VirtualDisplayConfig? {
        guard let selectedUUID else { return nil }
        return virtualDisplays.configs.first { $0.id == selectedUUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if virtualDisplays.configs.isEmpty {
                Text("Create a configuration in Virtual Display first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("Virtual Display")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Picker("", selection: $selectedConfigID) {
                        ForEach(virtualDisplays.configs) { config in
                            Text(verbatim: "\(config.name) · \(config.width)×\(config.height)")
                                .tag(config.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.caption)
                    .disabled(session.isRunning || session.isStarting)
                }

                if session.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("Running · Virtual display is main · Sleep prevention on")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        Task { @MainActor in
                            await session.stop()
                        }
                    } label: {
                        Label(session.isStopping ? "Stopping…" : "End Headless Session", systemImage: "stop.fill")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(session.isStopping)
                } else {
                    Button {
                        guard let id = selectedUUID else { return }
                        Task { @MainActor in
                            _ = await session.start(configID: id)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if session.isStarting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(session.isStarting ? "Starting…" : "Start Headless Session")
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedUUID == nil || session.isStarting)
                }

                if let error = session.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }

                Text("Starting a session creates and enables the selected virtual display and makes it the main display. Drag the game window onto this new screen, then press the power button on the physical display to turn it off. The system and displays will not sleep during the session. When you end it, the original main display is restored and the virtual display created for this session is turned off.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let config = selectedConfig {
                    Text(verbatim: "\(config.name) · \(config.width)×\(config.height)\(config.hiDPI ? " HiDPI" : "") · \(Int(config.refreshRate))Hz")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: ensureSelection)
        .onChange(of: virtualDisplays.configs) { _, _ in
            ensureSelection()
        }
    }

    private func ensureSelection() {
        guard !virtualDisplays.configs.isEmpty else {
            selectedConfigID = ""
            return
        }
        if let id = UUID(uuidString: selectedConfigID),
           virtualDisplays.configs.contains(where: { $0.id == id }) {
            return
        }
        selectedConfigID = virtualDisplays.configs[0].id.uuidString
    }
}
