import SwiftUI

/// 面板与菜单栏共用的数据。
final class PanelModel: ObservableObject {
    @Published var tab: Service = .codex
    @Published var codex = ServiceSnapshot(status: .loading)
    @Published var gemini = ServiceSnapshot(status: .loading)
    /// Codex 官方每日用量；nil = 还没回来或拉取失败（看 officialLoaded）。
    @Published var official: [String: Int64]? = nil
    @Published var officialLoaded = false
    @Published var range: TokenRange = .daily
    /// Gemini 本机 Token 历史；nil = 首次扫描没完成。
    @Published var geminiHistory: GeminiHistory? = nil
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

    func snapshot(_ s: Service) -> ServiceSnapshot { s == .codex ? codex : gemini }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar(model: model).zIndex(2)
            ServiceTabs(model: model).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                ServiceSection(service: model.tab, snap: model.snapshot(model.tab), now: model.now(),
                               onReauthorize: model.onReauthorizeKeychain)
                if model.tab == .codex, model.codex.status != .notLoggedIn, model.codex.status != .apiKeyOnly {
                    TokenChartSection(model: model, service: .codex)
                }
                if model.tab == .gemini {
                    // 本机数据不依赖登录：选中 Gemini 页签就显示。
                    TokenChartSection(model: model, service: .gemini)
                }
            }
            .padding(12)
        }
        .frame(width: 400)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(th.panelStroke, lineWidth: 0.5))
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
            ForEach(Service.allCases, id: \.self) { s in
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

// MARK: 账号行和额度卡

struct ServiceSection: View {
    let service: Service
    let snap: ServiceSnapshot
    let now: Date
    let onReauthorize: () -> Void
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
            if showAccount || sub != nil {
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
                VStack(alignment: .leading, spacing: 12) {
                    if snap.hasQuota {
                        Text("剩余额度").font(.system(size: 13, weight: .semibold)).foregroundColor(th.ink)
                            .padding(.bottom, -2)
                    }
                    if let w = snap.weekly { QuotaRow(title: "每周", window: w, now: now) }
                    if let f = snap.fiveHour { QuotaRow(title: "5 小时", window: f, now: now) }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        let low = QuotaLevel.of(remainingPercent: window.remainingPercent) == .critical
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundColor(th.ink2).lineLimit(1).fixedSize()
                (Text(MenuBarText.number(window.remainingPercent)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    + Text("%").font(.system(size: 10, weight: .medium)))
                    .foregroundColor(low ? Theme.red : th.ink)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if let r = window.resetsAt {
                    Text("\(Fmt.countdown(from: now, to: r))后重置").font(.system(size: 10).monospacedDigit())
                        .foregroundColor(th.ink3).lineLimit(1).fixedSize()
                }
            }
            QuotaBar(fraction: window.remainingPercent / 100, color: Theme.health(window.remainingPercent),
                     height: 5, track: th.track)
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

    func axisKeys(_ bars: [TokenBar]) -> [String] {
        switch model.range {
        case .daily: return bars.enumerated().filter { $0.offset % 7 == 0 }.map { $0.element.key }
        case .weekly: return bars.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element.key }
        case .monthly: return bars.map { $0.key }
        }
    }

    func axisLabel(_ key: String) -> String {
        let p = key.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return key }
        return model.range == .monthly ? "\(m)月" : "\(m)/\(d)"
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
    @Environment(\.colorScheme) private var scheme

    private let axisWidth: CGFloat = 40
    private let labelHeight: CGFloat = 18
    private let topPad: CGFloat = 6

    var body: some View {
        let th = Theme(scheme)
        let maxV = max(bars.map { $0.value }.max() ?? 0, 1)
        GeometryReader { geo in
            let plotW = geo.size.width - axisWidth
            let plotH = geo.size.height - labelHeight - topPad
            let slot = plotW / CGFloat(max(bars.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                    let y = topPad + plotH * (1 - f)
                    if f < 1 {
                        Path { p in p.move(to: CGPoint(x: axisWidth, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                            .stroke(th.ink.opacity(f == 0 ? 0.18 : 0.10),
                                    style: StrokeStyle(lineWidth: 0.5, dash: f == 0 ? [] : [2, 3]))
                    }
                    Text(Fmt.axisTokens(Int64(Double(maxV) * f)))
                        .font(.system(size: 10).monospacedDigit()).foregroundColor(th.ink.opacity(0.5))
                        .lineLimit(1)
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .position(x: (axisWidth - 6) / 2, y: y)
                }
                ForEach(Array(bars.enumerated()), id: \.element.key) { i, b in
                    let h = b.value > 0 ? max(plotH * CGFloat(Double(b.value) / Double(maxV)), 2) : 0
                    let x = axisWidth + slot * (CGFloat(i) + 0.5)
                    TopRounded(radius: 2)
                        .fill(Theme.gradient)
                        .opacity(active == nil || b.key == active ? 1 : 0.45)
                        .frame(width: max(slot * 0.64, 1), height: h)
                        .position(x: x, y: topPad + plotH - h / 2)
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
                    TooltipView(bar: bars[i])
                        .position(x: min(max(axisWidth + slot * (CGFloat(i) + 0.5), 64), geo.size.width - 64), y: 18)
                        .allowsHitTesting(false)
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
