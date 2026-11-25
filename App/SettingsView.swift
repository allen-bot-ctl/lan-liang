import SwiftUI

/// 设置窗口的数据（契约 0.2.0 §7 + 0.3.0 §3）：两项通用开关 + 监听服务回调；面板数据从 PanelModel 读。
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = false
    @Published var autoCheck = true
    @Published var availableUpdate: String? = nil
    var version = ""
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var setAutoCheck: (Bool) -> Void = { _ in }
    /// 拨监听服务开关（最后一个开着的由 ServiceSelection 拦下）。
    var setService: (Service, Bool) -> Void = { _, _ in }
    var onCheckUpdates: () -> Void = {}
    var onQuit: () -> Void = {}
}

/// 设置窗口（契约 0.3.0 §3）：宽 520 固定，三张卡片——监听服务、消耗汇总、通用，最下面一行信息。
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// 面板数据：登录状态、累计用量、监听服务；数据更新时窗口跟着刷新。
    @ObservedObject var panel: PanelModel
    @Environment(\.colorScheme) private var scheme
    @State private var quitHover = false
    @State private var linkHover = false

    var body: some View {
        let th = Theme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            servicesCard(th)
            summaryCard(th)
            generalCard(th)
            footer(th)
        }
        .padding(16)
        .frame(width: 520)
    }

    // MARK: 1. 监听服务

    func servicesCard(_ th: Theme) -> some View {
        let sel = panel.services
        return SettingsCard(title: "监听服务", detail: "开启的服务显示在菜单栏和面板里；只开一个时放大显示") {
            VStack(spacing: 0) {
                ForEach(Array(Service.allCases.enumerated()), id: \.element) { i, s in
                    if i > 0 { Rectangle().fill(th.line).frame(height: 0.5).padding(.leading, 50) }
                    ServiceToggleRow(service: s, snap: panel.snapshot(s), isOn: sel.isOn(s), canToggle: sel.canToggle(s),
                                     onChange: { on in model.setService(s, on) })
                }
                if sel.isSingle {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                        Text(SettingsText.keepOneHint).font(.system(size: 11)).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(th.ink2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: 2. 消耗汇总（契约 0.3.0 §4）

    func summaryCard(_ th: Theme) -> some View {
        let sum = UsageSummary.make(selection: panel.services, official: panel.official,
                                    officialLoaded: panel.officialLoaded, gemini: panel.geminiHistory)
        return SettingsCard(title: "消耗汇总", detail: panel.services.isSingle ? "仅已开启的服务" : "Codex + Gemini 累计") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("累计").font(.system(size: 12)).foregroundColor(th.ink2).lineLimit(1).fixedSize()
                    if sum.incomplete {
                        Text("不完整").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.14)))
                    }
                    Spacer(minLength: 8)
                    if sum.loading {
                        Text("正在统计…").font(.system(size: 13)).foregroundColor(th.ink3).lineLimit(1).fixedSize()
                    } else {
                        Text(sum.total.map { Fmt.tokens($0) } ?? "—")
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .foregroundColor(th.ink).lineLimit(1).fixedSize()
                        Text("Tokens").font(.system(size: 13)).foregroundColor(th.ink2).lineLimit(1).fixedSize()
                    }
                }
                .frame(height: 34)
                if sum.showsSplit {
                    SplitBar(codexShare: sum.items.first(where: { $0.service == .codex })?.share ?? 0)
                }
                HStack(spacing: 18) {
                    ForEach(sum.items, id: \.service) { item in
                        LegendItem(item: item)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: 3. 通用

    func generalCard(_ th: Theme) -> some View {
        SettingsCard(title: nil, detail: nil) {
            VStack(spacing: 0) {
                SettingRow(title: "登录时启动", detail: "开机后自动出现在菜单栏",
                           isOn: Binding(get: { model.launchAtLogin },
                                         set: { model.launchAtLogin = $0; model.setLaunchAtLogin($0) }))
                Rectangle().fill(th.line).frame(height: 0.5).padding(.leading, 12)
                SettingRow(title: "自动检查更新", detail: "有新版本时在面板上提示",
                           isOn: Binding(get: { model.autoCheck },
                                         set: { model.autoCheck = $0; model.setAutoCheck($0) }))
            }
        }
    }

    // MARK: 信息行

    func footer(_ th: Theme) -> some View {
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
}

/// 设置窗口里的卡片：圆角 10，卡片底和描边沿用 0.2.0；可选标题 13pt 半粗 + 说明 10pt。
struct SettingsCard<Content: View>: View {
    let title: String?
    let detail: String?
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(title: String?, detail: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        let th = Theme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            if let t = title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t).font(.system(size: 13, weight: .semibold)).foregroundColor(th.ink).lineLimit(1).fixedSize()
                    if let d = detail {
                        Text(d).font(.system(size: 10)).foregroundColor(th.ink3).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(th.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(th.line, lineWidth: 0.5))
    }
}

/// 监听服务的一行（行高 48）：28×28 叠色底上的服务图标、名称 13pt、账号行 10pt，靠右开关。
struct ServiceToggleRow: View {
    let service: Service
    let snap: ServiceSnapshot
    let isOn: Bool
    let canToggle: Bool
    let onChange: (Bool) -> Void
    @State private var cursorPushed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(th.sel)
                Image(systemName: service == .codex ? "terminal" : "sparkles")
                    .font(.system(size: 14)).foregroundColor(th.ink)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title).font(.system(size: 13)).foregroundColor(th.ink).lineLimit(1)
                Text(SettingsText.accountLine(service: service, snap: snap, isOn: isOn))
                    .font(.system(size: 10)).foregroundColor(th.ink3)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // 最后一个开着的服务：开关置灰（透明度 45%），鼠标显示禁止手型。
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(!canToggle)
                .opacity(canToggle ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside && !canToggle && !cursorPushed {
                        NSCursor.operationNotAllowed.push()
                        cursorPushed = true
                    } else if !inside && cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }
}

/// 消耗汇总图例：色块 + 「Codex 193.00亿 97.6%」。
struct LegendItem: View {
    let item: UsageSummary.Item
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.service == .codex ? Theme.codexFill : Theme.geminiFill)
                .frame(width: 8, height: 8)
            Text(item.service.title).font(.system(size: 12)).foregroundColor(th.ink2).lineLimit(1).fixedSize()
            if let v = item.tokens {
                Text(Fmt.tokens(v)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(th.ink).lineLimit(1).fixedSize()
            } else if item.state == .unavailable {
                Text("—").font(.system(size: 12, weight: .semibold)).foregroundColor(th.ink3).lineLimit(1).fixedSize()
                Text(SettingsText.unavailable(item.service)).font(.system(size: 11)).foregroundColor(th.ink3)
                    .lineLimit(1).fixedSize()
            } else {
                Text("…").font(.system(size: 12)).foregroundColor(th.ink3).lineLimit(1).fixedSize()
            }
            if let sh = item.share {
                Text(UsageSummary.percent(sh)).font(.system(size: 11).monospacedDigit())
                    .foregroundColor(th.ink3).lineLimit(1).fixedSize()
            }
        }
    }
}

/// 8pt 占比条：Codex 橙色渐变、Gemini #8E8CF5，中间留 2pt 缝。
struct SplitBar: View {
    let codexShare: Double

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = max(geo.size.width - gap, 0)
            let cw = w * CGFloat(min(max(codexShare, 0), 1))
            HStack(spacing: gap) {
                Capsule().fill(Theme.codexFill).frame(width: cw)
                Capsule().fill(Theme.geminiFill).frame(width: w - cw)
            }
        }
        .frame(height: 8)
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
