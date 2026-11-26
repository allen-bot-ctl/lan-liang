import SwiftUI

/// 面板与菜单栏共用的数据。
final class PanelModel: ObservableObject {
    @Published var tab: Service = .codex
    @Published var showsSettings = false
    /// 监听服务（契约 0.3.0 §1）：关掉的服务不显示页签和内容。
    @Published var services = ServiceSelection.all
    @Published var codex = ServiceSnapshot(status: .loading)
    @Published var gemini = ServiceSnapshot(status: .loading)
    /// Codex 官方每日用量；nil = 还没回来或拉取失败（看 officialLoaded）。
    @Published var official: [String: Int64]? = nil
    @Published var officialLoaded = false
    @Published var range: TokenRange = .daily
    /// Gemini 本机 Token 历史；nil = 首次扫描没完成。
    @Published var geminiHistory: GeminiHistory? = nil
    @Published var codexModelActivity: DailyModelWeights? = nil
    @Published var loadedCodexModelActivity = false
    @Published var refreshing = false
    /// 上次刷新完成的时间（契约 0.2.0 §3）。
    @Published var lastUpdated: Date? = nil
    /// Sparkle 找到的新版本号；nil = 没有新版本。
    @Published var availableUpdate: String? = nil
    /// 截图用：强制悬停某根柱子（从右往左数第几根）。
    @Published var hoverKey: String? = nil
    /// 截图用：强制悬停顶栏按钮（refresh / update / settings）。
    @Published var hoverButton: String? = nil
    var appVersion = ""
    var now: () -> Date = { Date() }
    var onRefresh: () -> Void = {}
    var onReauthorizeKeychain: () -> Void = {}
    var onCheckUpdates: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    func returnToDashboard() { showsSettings = false }

    func snapshot(_ s: Service) -> ServiceSnapshot { s == .codex ? codex : gemini }

    /// 面板实际显示的服务：当前页签关掉了就显示第一个开着的。
    var shownTab: Service { services.isOn(tab) ? tab : (services.enabled.first ?? tab) }
}

/// 使用同一宿主和面板切换页面；主视图留在树上，保留当前页签和滚动位置。
struct PanelRoot: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var settings: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            PanelView(model: model)
                .opacity(model.showsSettings ? 0 : 1)
                .allowsHitTesting(!model.showsSettings)
                .accessibilityHidden(model.showsSettings)
            if model.showsSettings {
                SettingsView(model: settings, panel: model, onBack: model.returnToDashboard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme(scheme).panelStroke, lineWidth: 0.5)
            .allowsHitTesting(false))
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar(model: model).zIndex(2)
            if model.services.isSingle {
                // 只开一个服务：去掉页签条，换成服务头卡片（契约 0.3.0 §2）。
                SingleServiceHeader(service: model.shownTab, snap: model.snapshot(model.shownTab), now: model.now())
                    .padding(.horizontal, 12)
            } else {
                ServiceTabs(model: model).padding(.horizontal, 12)
            }
            // 顶栏和页签固定；超出的内容可滚动。切页签时自动回到顶部。
            ScrollView(.vertical, showsIndicators: true) { sections }
                .id(model.shownTab)
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var sections: some View {
        let tab = model.shownTab
        return VStack(alignment: .leading, spacing: 8) {
            ServiceSection(service: tab, snap: model.snapshot(tab), now: model.now(),
                           onReauthorize: model.onReauthorizeKeychain, single: model.services.isSingle)
            if tab == .codex, model.codex.status != .notLoggedIn, model.codex.status != .apiKeyOnly {
                TokenChartSection(model: model, service: .codex)
            }
            if tab == .gemini {
                // 本机数据不依赖登录：选中 Gemini 页签就显示。
                TokenChartSection(model: model, service: .gemini)
            }
        }
        .padding(12)
        .frame(width: 400, alignment: .leading)
    }
}

// MARK: 顶栏

struct HeaderBar: View {
    @ObservedObject var model: PanelModel
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        let active = hovered ?? model.hoverButton
        HStack(spacing: 8) {
            AppLogo(size: 20)
            Text("栏量").font(.system(size: 15, weight: .semibold)).foregroundColor(th.ink)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: Date(), by: 30)) { ctx in
                Text(PanelText.updated(last: model.lastUpdated, now: ctx.date, refreshing: model.refreshing))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(th.ink3)
                    .lineLimit(1).fixedSize()
            }
            HStack(spacing: 2) {
                HeaderButton(id: "refresh", symbol: "arrow.clockwise", spinning: model.refreshing, dot: false,
                             hovered: $hovered, forced: model.hoverButton, action: { model.onRefresh() })
                HeaderButton(id: "update", symbol: "arrow.down.circle", spinning: false, dot: model.availableUpdate != nil,
                             hovered: $hovered, forced: model.hoverButton, action: { model.onCheckUpdates() })
                HeaderButton(id: "settings", symbol: "gearshape", spinning: false, dot: false,
                             hovered: $hovered, forced: model.hoverButton, action: { model.onOpenSettings() })
            }
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 44)
        .overlay(alignment: .topTrailing) {
            if let a = active {
                TipBubble(lines: tipLines(a))
                    .offset(x: tipOffset(a), y: 36)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 气泡右边对齐到按钮右边（按钮 26 宽、间距 2，右内边距 8）。
    func tipOffset(_ id: String) -> CGFloat {
        switch id {
        case "refresh": return -8 - 56
        case "update": return -8 - 28
        default: return -8
        }
    }

    func tipLines(_ id: String) -> [String] {
        switch id {
        case "refresh":
            if model.refreshing { return ["正在刷新…"] }
            if let a = PanelText.ago(last: model.lastUpdated, now: Date()) { return ["刷新", "上次更新 \(a)"] }
            return ["刷新"]
        case "update":
            if let v = model.availableUpdate { return ["有新版本 \(v)", "点击查看更新内容并安装"] }
            return ["检查更新", "当前 \(model.appVersion)，已是最新"]
        default:
            return ["设置"]
        }
    }
}

struct HeaderButton: View {
    let id: String
    let symbol: String
    let spinning: Bool
    let dot: Bool
    @Binding var hovered: String?
    let forced: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        let on = hovered == id || forced == id
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spinning)
                .foregroundColor(on ? th.ink : th.ink2)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? th.hover : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle().fill(Theme.red).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(th.dark ? Color.black.opacity(0.5) : Color.white, lineWidth: 1.5))
                            .offset(x: -4, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in
            if inside { hovered = id; NSCursor.pointingHand.push() } else { if hovered == id { hovered = nil }; NSCursor.pop() }
        }
    }
}

// MARK: 服务页签

struct ServiceTabs: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.services.enabled, id: \.self) { s in
                ServiceTab(service: s, snap: model.snapshot(s), selected: model.tab == s) { model.tab = s }
            }
        }
    }
}

struct ServiceTab: View {
    let service: Service
    let snap: ServiceSnapshot
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        let w = PanelText.tabWindow(snap)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: service == .codex ? "terminal" : "sparkles").font(.system(size: 14))
                    Text(service.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(PanelText.tabPercent(snap)).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(th.ink2).lineLimit(1).fixedSize()
                }
                QuotaBar(fraction: (w?.remainingPercent ?? 0) / 100,
                         color: w.map { Theme.health($0.remainingPercent) } ?? Color.clear, height: 4, track: th.track)
            }
            .foregroundColor(selected || hovering ? th.ink : th.ink2)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? th.sel : (hovering ? th.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}

/// 「仅一个」状态的服务头卡片（契约 0.3.0 §2）：叠色底、圆角 10；图标 16pt 放在 28×28 圆角底上、
/// 名称 15pt 半粗、套餐徽章、掩码邮箱；Codex 靠右「剩 N 天」。
struct SingleServiceHeader: View {
    let service: Service
    let snap: ServiceSnapshot
    let now: Date
    @Environment(\.colorScheme) private var scheme

    /// Codex 订阅剩余天数：只取「剩 N 天」那一段；过期时「订阅已过期」。
    var daysLeft: (text: String, expired: Bool)? {
        guard service == .codex, snap.status != .notLoggedIn, snap.status != .apiKeyOnly else { return nil }
        let line = CodexSubscription.line(raw: snap.subscriptionUntil, planRaw: snap.planRaw,
                                          planIsLive: snap.planIsLive ?? false, now: now)
        guard let t = CodexSubscription.text(line) else { return nil }
        return (t.components(separatedBy: " · ").last ?? t, line == .expired)
    }

    var body: some View {
        let th = Theme(scheme)
        let showAccount = snap.status != .notLoggedIn && snap.status != .keychainDenied
        let days = daysLeft
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(th.segOn)
                Image(systemName: service == .codex ? "terminal" : "sparkles")
                    .font(.system(size: 16)).foregroundColor(th.ink)
            }
            .frame(width: 28, height: 28)
            Text(service.title).font(.system(size: 15, weight: .semibold)).foregroundColor(th.ink)
                .lineLimit(1).fixedSize()
            if showAccount, let p = snap.plan {
                Text(p).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.gradient))
            }
            if showAccount, let e = snap.email {
                Text(Fmt.maskEmail(e)).font(.system(size: 12)).foregroundColor(th.ink2)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let d = days {
                Text(d.text).font(.system(size: 12).monospacedDigit())
                    .foregroundColor(d.expired ? Theme.red : Theme.green)
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(th.sel))
    }
}

// MARK: 账号行和额度卡

struct ServiceSection: View {
    let service: Service
    let snap: ServiceSnapshot
    let now: Date
    let onReauthorize: () -> Void
    /// 只开一个服务：账号行挪到服务头卡片，额度放大（契约 0.3.0 §2）。
    var single = false
    @Environment(\.colorScheme) private var scheme

    /// 订阅行（判断逻辑同 0.1.5）；有效期行去掉「订阅有效期」前缀，写成「至 yyyy/MM/dd · 剩 N 天」（契约 0.2.0 §5）。
    var subscription: (text: String, expired: Bool)? {
        guard service == .codex, snap.status != .notLoggedIn, snap.status != .apiKeyOnly else { return nil }
        let line = CodexSubscription.line(raw: snap.subscriptionUntil, planRaw: snap.planRaw,
                                          planIsLive: snap.planIsLive ?? false, now: now)
        guard let t = CodexSubscription.text(line) else { return nil }
        let prefix = "订阅有效期"
        return (t.hasPrefix(prefix) ? String(t.dropFirst(prefix.count)) : t, line == .expired)
    }

    var body: some View {
        let th = Theme(scheme)
        let sub = subscription
        let showAccount = snap.status != .notLoggedIn && snap.status != .keychainDenied && (snap.plan != nil || snap.email != nil)
        VStack(alignment: .leading, spacing: 8) {
            if !single, showAccount || sub != nil {
                HStack(spacing: 8) {
                    if showAccount, let p = snap.plan {
                        Text(p).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.gradient))
                    }
                    if showAccount, let e = snap.email {
                        Text(Fmt.maskEmail(e)).font(.system(size: 12)).foregroundColor(th.ink2)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if let s = sub {
                        Text(s.text).font(.system(size: 12).monospacedDigit())
                            .foregroundColor(s.expired ? Theme.red : Theme.green)
                            .lineLimit(1).fixedSize()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            let msg = snap.message(for: service)
            if snap.hasQuota || msg != nil || snap.status == .keychainDenied {
                VStack(alignment: .leading, spacing: single ? 14 : 12) {
                    if snap.hasQuota {
                        Text("剩余额度").font(.system(size: 13, weight: .semibold)).foregroundColor(th.ink)
                            .padding(.bottom, -2)
                    }
                    if let w = snap.weekly { QuotaRow(title: "每周", window: w, now: now, large: single) }
                    if let f = snap.fiveHour { QuotaRow(title: "5 小时", window: f, now: now, large: single) }
                    if let m = msg {
                        let isError = snap.status == .fetchFailed || snap.status == .loginExpired
                        Text(m).font(.system(size: 12)).foregroundColor(isError ? Theme.red : th.ink2)
                            .frame(maxWidth: .infinity, alignment: snap.hasQuota ? .leading : .center)
                            .padding(.vertical, snap.status == .notLoggedIn ? 24 : 0)
                    }
                    if snap.status == .keychainDenied {
                        Button("重新授权", action: onReauthorize)
                    }
                }
                .card(th)
            }
        }
    }
}

struct QuotaRow: View {
    let title: String
    let window: QuotaWindow
    let now: Date
    /// 「仅一个」状态：百分比 28pt、进度条 6pt（契约 0.3.0 §2）。
    var large = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        let low = QuotaLevel.of(remainingPercent: window.remainingPercent) == .critical
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundColor(th.ink2).lineLimit(1).fixedSize()
                (Text(MenuBarText.number(window.remainingPercent)).font(.system(size: large ? 28 : 15, weight: .semibold).monospacedDigit())
                    + Text("%").font(.system(size: large ? 13 : 10, weight: .medium)))
                    .foregroundColor(low ? Theme.red : th.ink)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if let r = window.resetsAt {
                    Text("\(Fmt.countdown(from: now, to: r))后重置").font(.system(size: 10).monospacedDigit())
                        .foregroundColor(th.ink3).lineLimit(1).fixedSize()
                }
            }
            QuotaBar(fraction: window.remainingPercent / 100, color: Theme.health(window.remainingPercent),
                     height: large ? 6 : 5, track: th.track)
        }
    }
}

struct TokenChartSection: View {
    @ObservedObject var model: PanelModel
    let service: Service
    @State private var hover: String?
    @Environment(\.colorScheme) private var scheme

    /// Codex：只画官方数据；Gemini：只有本机（Antigravity 对话库）。
    var series: [String: Int64] { service == .codex ? (model.official ?? [:]) : (model.geminiHistory?.daily ?? [:]) }

    var bars: [TokenBar] {
        TokenSeries.bars(range: model.range, official: nil, local: series,
                         now: model.now(), calendar: TokenSeries.calendar())
    }

    static let chartHeight: CGFloat = 132

    var body: some View {
        let th = Theme(scheme)
        let bars = self.bars
        let active = hover ?? (model.hoverKey == "auto" ? bars.max(by: { $0.value < $1.value })?.key : model.hoverKey)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                Text("Token 用量").font(.system(size: 13, weight: .semibold)).foregroundColor(th.ink).lineLimit(1).fixedSize()
                Text(service == .gemini ? "仅本机" : "官方").font(.system(size: 10)).foregroundColor(th.ink3).lineLimit(1).fixedSize()
                if failedCount > 0 {
                    Text("· \(failedCount) 个对话读取失败").font(.system(size: 10).monospacedDigit()).foregroundColor(th.ink3)
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                RangeSegment(range: $model.range, compact: failedCount > 0)
            }
            if let st = status {
                if st.text == "正在统计…" {
                    LoadingBars(text: st.text)
                } else if service == .codex {
                    FailedState(text: st.text, onRetry: { model.onRefresh() })
                } else {
                    Text(st.text).font(.system(size: 12)).foregroundColor(st.isError ? Theme.red : th.ink3)
                        .frame(maxWidth: .infinity, minHeight: Self.chartHeight, maxHeight: Self.chartHeight, alignment: .center)
                }
            } else {
                BarChart(bars: bars, active: active, axisKeys: Set(axisKeys(bars)), axisLabel: axisLabel, hover: $hover)
                    .frame(height: Self.chartHeight)
            }
        }
        .card(th)
    }

    /// 部分对话读取失败的个数（只有 Gemini 画图时才有）；有时把区间切换收窄，让标题行一行放下。
    var failedCount: Int {
        guard service == .gemini, case let .chart(failed)? = model.geminiHistory?.display else { return 0 }
        return failed
    }

    /// 图区的状态文案（契约 0.1.4 §4、0.1.5 §5）；nil = 画图。
    var status: (text: String, isError: Bool)? {
        if service == .codex {
            if !model.officialLoaded { return ("正在统计…", false) }
            return model.official == nil ? ("官方用量暂时拿不到", false) : nil
        }
        guard let h = model.geminiHistory else { return ("正在统计…", false) }
        let d = h.display
        guard let msg = GeminiHistory.message(d) else { return nil }
        return (msg, d == .allFailed)
    }

    func axisKeys(_ bars: [TokenBar]) -> [String] { Self.axisKeysFor(bars, range: model.range) }

    func axisLabel(_ key: String) -> String { Self.axisLabelFor(key, range: model.range) }

    /// 横轴标哪几根（面板和设置窗口共用）。
    static func axisKeysFor(_ bars: [TokenBar], range: TokenRange) -> [String] {
        switch range {
        case .daily: return bars.enumerated().filter { $0.offset % 7 == 0 }.map { $0.element.key }
        case .weekly: return bars.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element.key }
        case .monthly: return bars.map { $0.key }
        }
    }

    static func axisLabelFor(_ key: String, range: TokenRange) -> String {
        let p = key.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return key }
        return range == .monthly ? "\(m)月" : "\(m)/\(d)"
    }
}

/// 日 / 周 / 月分段（自绘，替换系统分段控件）。
struct RangeSegment: View {
    @Binding var range: TokenRange
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        HStack(spacing: 0) {
            ForEach(TokenRange.allCases, id: \.self) { r in
                let on = r == range
                Text(r.title)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? th.ink : th.ink2)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, compact ? 7 : 10).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? th.segOn : Color.clear)
                        .shadow(color: Color.black.opacity(on ? 0.12 : 0), radius: 1, x: 0, y: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { range = r }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(th.track))
    }
}

/// 加载态：14 根灰色占位柱，1.4 秒脉冲。
struct LoadingBars: View {
    let text: String
    @State private var dim = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<14, id: \.self) { i in
                    TopRounded(radius: 3).fill(th.track)
                        .frame(maxWidth: .infinity)
                        .frame(height: 84 * CGFloat(20 + (i * 37) % 60) / 100)
                }
            }
            .frame(height: 84, alignment: .bottom)
            .padding(.horizontal, 6)
            .opacity(dim ? 0.45 : 1)
            Text(text).font(.system(size: 12)).foregroundColor(th.ink3)
        }
        .frame(maxWidth: .infinity, minHeight: TokenChartSection.chartHeight, maxHeight: TokenChartSection.chartHeight)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// 失败态：云图标、文案、「重试」（只调用现有刷新）。
struct FailedState: View {
    let text: String
    let onRetry: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        VStack(spacing: 8) {
            Image(systemName: "icloud.slash").font(.system(size: 22)).foregroundColor(th.ink3)
            Text(text).font(.system(size: 12)).foregroundColor(th.ink3)
            Button(action: onRetry) {
                Text("重试").font(.system(size: 12)).foregroundColor(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? th.hover : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: TokenChartSection.chartHeight, maxHeight: TokenChartSection.chartHeight)
    }
}

/// 自绘柱状图（不用 Swift Charts：它在没有 GPU 的 Intel CI 机器上会触发 Metal 断言）。
struct BarChart: View {
    let bars: [TokenBar]
    let active: String?
    let axisKeys: Set<String>
    let axisLabel: (String) -> String
    @Binding var hover: String?
    /// 堆叠柱（0.3.1 设置窗口消耗汇总）：按柱子 key 给出 Codex（下）和 Gemini（上）两段；nil = 单色柱（面板）。
    var stacks: [String: StackedBar]? = nil
    /// 悬停时用四行堆叠气泡（日期、Codex、Gemini、合计）；false = 面板原样的两行气泡。
    var stackedTip = false
    @Environment(\.colorScheme) private var scheme

    /// 刻度列宽：按最宽的刻度文字量出来（「44.83亿」「8900万」不截断）。
    static func axisWidth(_ labels: [String]) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let w = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(28, ceil(w) + 8)
    }
    private let labelHeight: CGFloat = 18
    private let topPad: CGFloat = 6

    var body: some View {
        let th = Theme(scheme)
        let maxV = max(bars.map { $0.value }.max() ?? 0, 1)
        let ticks = [0.0, 0.5, 1.0].map { Fmt.axisTokens(Int64(Double(maxV) * $0)) }
        let axisWidth = Self.axisWidth(ticks)
        GeometryReader { geo in
            let plotW = geo.size.width - axisWidth
            let plotH = geo.size.height - labelHeight - topPad
            let slot = plotW / CGFloat(max(bars.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array([0.0, 0.5, 1.0].enumerated()), id: \.offset) { idx, f in
                    let y = topPad + plotH * (1 - f)
                    if f < 1 {
                        Path { p in p.move(to: CGPoint(x: axisWidth, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                            .stroke(th.ink.opacity(f == 0 ? 0.18 : 0.10),
                                    style: StrokeStyle(lineWidth: 0.5, dash: f == 0 ? [] : [2, 3]))
                    }
                    Text(ticks[idx])
                        .font(.system(size: 10).monospacedDigit()).foregroundColor(th.ink.opacity(0.5))
                        .lineLimit(1).fixedSize()
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .position(x: (axisWidth - 6) / 2, y: y)
                }
                ForEach(Array(bars.enumerated()), id: \.element.key) { i, b in
                    let h = b.value > 0 ? max(plotH * CGFloat(Double(b.value) / Double(maxV)), 2) : 0
                    let x = axisWidth + slot * (CGFloat(i) + 0.5)
                    if let st = stacks?[b.key], st.total > 0 {
                        // Codex 橙色在下、Gemini #8E8CF5 在上；只有一段时整根柱子就是那一段的颜色。
                        let hb = h * CGFloat(Double(st.codex) / Double(st.total))
                        // 上下两段不重叠（降透明时不会透出底下那段的颜色）。
                        VStack(spacing: 0) {
                            TopRounded(radius: 2).fill(st.gemini > 0 ? Theme.geminiFill : Theme.codexFill)
                            if st.gemini > 0 && st.codex > 0 {
                                Rectangle().fill(Theme.codexFill).frame(height: hb)
                            }
                        }
                        .opacity(active == nil || b.key == active ? 1 : 0.45)
                        .frame(width: max(slot * 0.64, 1), height: h)
                        .position(x: x, y: topPad + plotH - h / 2)
                    } else {
                        TopRounded(radius: 2)
                            .fill(Theme.gradient)
                            .opacity(active == nil || b.key == active ? 1 : 0.45)
                            .frame(width: max(slot * 0.64, 1), height: h)
                            .position(x: x, y: topPad + plotH - h / 2)
                    }
                    if axisKeys.contains(b.key) {
                        Text(axisLabel(b.key)).font(.system(size: 10).monospacedDigit()).foregroundColor(th.ink.opacity(0.5))
                            .fixedSize()
                            .position(x: x, y: topPad + plotH + labelHeight / 2 + 1)
                    }
                }
                if let k = active, let i = bars.firstIndex(where: { $0.key == k }) {
                    let x = axisWidth + slot * (CGFloat(i) + 0.5)
                    Path { p in p.move(to: CGPoint(x: x, y: topPad)); p.addLine(to: CGPoint(x: x, y: topPad + plotH)) }
                        .stroke(th.ink.opacity(0.25), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let i = Int((p.x - axisWidth) / slot)
                            hover = (p.x >= axisWidth && i >= 0 && i < bars.count) ? bars[i].key : nil
                        case .ended:
                            hover = nil
                        }
                    }
                if let k = active, let i = bars.firstIndex(where: { $0.key == k }) {
                    if stackedTip, let st = stacks?[k] {
                        // 四行气泡（契约 0.3.1 §2）：按气泡实际宽度夹在图区内，竖直放在图区上部不出界。
                        StackedTipView(stack: st)
                            .position(x: min(max(axisWidth + slot * (CGFloat(i) + 0.5), axisWidth + 62), geo.size.width - 62),
                                      y: 38)
                            .allowsHitTesting(false)
                    } else {
                        TooltipView(bar: bars[i])
                            .position(x: min(max(axisWidth + slot * (CGFloat(i) + 0.5), 64), geo.size.width - 64), y: 18)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

/// 悬停气泡：日期（或区间）和「N Tokens」两行。
struct TooltipView: View {
    let bar: TokenBar

    var body: some View {
        TipBubble(lines: [bar.label, "\(Fmt.tokens(bar.value)) Tokens"], boldLine: 1)
    }
}

/// 堆叠柱的悬停气泡（契约 0.3.1 §2）：日期；色块 +「Codex 2.86亿」；色块 +「Gemini 6600万」；「合计 3.52亿 Tokens」半粗。
struct StackedTipView: View {
    let stack: StackedBar
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        let lines = StackedSeries.tipLines(stack)
        VStack(alignment: .leading, spacing: 1) {
            Text(lines[0]).lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(Theme.codexFill).frame(width: 6, height: 6)
                Text(lines[1]).lineLimit(1)
            }
            HStack(spacing: 4) {
                Circle().fill(Theme.geminiFill).frame(width: 6, height: 6)
                Text(lines[2]).lineLimit(1)
            }
            Text(lines[3]).fontWeight(.semibold).lineLimit(1)
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundColor(th.tipInk)
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(th.tipBg))
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        .fixedSize()
    }
}
