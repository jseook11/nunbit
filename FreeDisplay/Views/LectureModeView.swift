import SwiftUI
import Foundation

/// Lecture mode: keep playback alive with the physical monitor switched off.
/// It deliberately does not create a virtual display, because FairPlay/HDCP
/// protected course videos do not play on virtual displays.
struct LectureModeView: View {
    @ObservedObject private var sleep = SleepAssertionService.shared

    private var isOn: Binding<Bool> {
        Binding(
            get: { sleep.isHeld(by: .lecture) },
            set: { enabled in
                sleep.setHeld(
                    enabled,
                    by: .lecture,
                    reason: "FreeDisplay lecture playback",
                    preventDisplaySleep: false
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "play.rectangle.fill", color: .green)
                        .accessibilityHidden(true)
                    Text("保持播放（防止系统睡眠）")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if sleep.isHeld(by: .lecture) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("系统保持唤醒；显示器可正常休眠")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button {
                    sleepDisplaysNow()
                } label: {
                    Label("立即关闭显示器", systemImage: "display")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("让显示器立即休眠，但 Mac 与播放继续运行；按键或移动鼠标即可唤醒")
            }

            Text("不会创建虚拟显示器，网课与 FairPlay/DRM 视频可正常播放。开启后可以等待显示器自动休眠，或点上面的按钮立即关屏；Mac 会保持唤醒并继续播放。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func sleepDisplaysNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }
}
