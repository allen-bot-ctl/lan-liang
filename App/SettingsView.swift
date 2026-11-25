import SwiftUI

/// 设置窗口的数据（契约 0.2.0 §7）：只有两项开关。
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = false
    @Published var autoCheck = true
    @Published var availableUpdate: String? = nil
    var version = ""
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var setAutoCheck: (Bool) -> Void = { _ in }
    var onCheckUpdates: () -> Void = {}
    var onQuit: () -> Void = {}
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    @State private var quitHover = false
    @State private var linkHover = false

    var body: some View {
        let th = Theme(scheme)
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                SettingRow(title: "登录时启动", detail: "开机后自动出现在菜单栏",
                           isOn: Binding(get: { model.launchAtLogin },
                                         set: { model.launchAtLogin = $0; model.setLaunchAtLogin($0) }))
                Rectangle().fill(th.line).frame(height: 0.5).padding(.leading, 12)
                SettingRow(title: "自动检查更新", detail: "有新版本时在面板上提示",
                           isOn: Binding(get: { model.autoCheck },
                                         set: { model.autoCheck = $0; model.setAutoCheck($0) }))
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(th.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(th.line, lineWidth: 0.5))

            HStack(spacing: 8) {
                AppLogo(size: 16)
                Text("栏量 \(model.version)").font(.system(size: 12).monospacedDigit()).foregroundColor(th.ink2)
                    .lineLimit(1).fixedSize()
                if let v = model.availableUpdate {
                    Text("\(v) 可用").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(Theme.red)
                        .lineLimit(1).fixedSize()
                }
                Button(action: { model.onCheckUpdates() }) {
                    Text("检查更新").font(.system(size: 12)).foregroundColor(Theme.accent)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(linkHover ? th.hover : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .onHover { linkHover = $0 }
                Spacer(minLength: 4)
                Button(action: { model.onQuit() }) {
                    Text("退出栏量").font(.system(size: 12)).foregroundColor(quitHover ? Theme.red : th.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(quitHover ? Theme.red.opacity(0.1) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .onHover { quitHover = $0 }
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundColor(th.ink)
                Text(detail).font(.system(size: 10)).foregroundColor(th.ink3)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}
