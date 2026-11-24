import SwiftUI

/// 面板与菜单栏共用的数据。
final class PanelModel: ObservableObject {
    @Published var tab: Service = .codex
    @Published var codex = ServiceSnapshot(status: .loading)
    @Published var gemini = ServiceSnapshot(status: .loading)
    @Published var official: [String: Int64]? = nil
    @Published var local: [String: Int64] = [:]
    @Published var range: TokenRange = .daily
    @Published var refreshing = false
    /// 截图用：强制悬停某根柱子（从右往左数第几根）。
    @Published var hoverKey: String? = nil
    var now: () -> Date = { Date() }
    var onRefresh: () -> Void = {}
    var onReauthorizeKeychain: () -> Void = {}

    func snapshot(_ s: Service) -> ServiceSnapshot { s == .codex ? codex : gemini }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("", selection: $model.tab) {
                    ForEach(Service.allCases, id: \.self) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(action: { model.onRefresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(model.refreshing ? 360 : 0))
                        .animation(model.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: model.refreshing)
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            ServiceSection(service: model.tab, snap: model.snapshot(model.tab), now: model.now(),
                           onReauthorize: model.onReauthorizeKeychain)
            if model.tab == .codex, model.codex.status != .notLoggedIn, model.codex.status != .apiKeyOnly {
                Divider()
                TokenChartSection(model: model)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct ServiceSection: View {
    let service: Service
    let snap: ServiceSnapshot
    let now: Date
    let onReauthorize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.status != .notLoggedIn, snap.status != .keychainDenied, snap.plan != nil || snap.email != nil {
                HStack(spacing: 8) {
                    if let p = snap.plan {
                        Text(p).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
                            .foregroundColor(.orange)
                    }
                    if let e = snap.email { Text(Fmt.maskEmail(e)).font(.system(size: 13)).foregroundColor(.secondary) }
                    Spacer()
                }
            }
            if service == .codex, let until = snap.subscriptionUntil, snap.status != .notLoggedIn {
                if until <= now {
                    Text("订阅已过期").font(.system(size: 12)).foregroundColor(.red)
                } else {
                    Text("订阅有效期至 \(Fmt.day(until)) · \(Fmt.countdown(from: now, to: until))")
                        .font(.system(size: 12)).foregroundColor(.green)
                }
            }
            if let w = snap.weekly { QuotaRow(title: "周剩余", window: w, now: now) }
            if let f = snap.fiveHour { QuotaRow(title: "5 小时剩余", window: f, now: now) }
            if let msg = snap.message(for: service) {
                let isError = snap.status == .fetchFailed || snap.status == .loginExpired
                Text(msg).font(.system(size: 12)).foregroundColor(isError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, snap.status == .notLoggedIn ? 24 : 0)
            }
            if snap.status == .keychainDenied {
                Button("重新授权", action: onReauthorize)
            }
        }
    }
}

struct QuotaRow: View {
    let title: String
    let window: QuotaWindow
    let now: Date

    var color: Color {
        switch QuotaLevel.of(remainingPercent: window.remainingPercent) {
        case .normal: return .green
        case .low: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title) \(MenuBarText.percent(window.remainingPercent))").font(.system(size: 12, weight: .medium))
                Spacer()
                if let r = window.resetsAt {
                    Text("\(Fmt.countdown(from: now, to: r))后重置").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            // 自绘进度条：macOS 的 ProgressView 不认 tint，会画成灰色
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(window.remainingPercent / 100))
                }
            }
            .frame(height: 6)
        }
    }
}

struct TokenChartSection: View {
    @ObservedObject var model: PanelModel
    @State private var hover: String?

    var bars: [TokenBar] {
        TokenSeries.bars(range: model.range, official: model.official, local: model.local,
                         now: model.now(), calendar: TokenSeries.calendar())
    }

    var body: some View {
        let bars = self.bars
        let active = hover ?? (model.hoverKey == "auto" ? bars.max(by: { $0.value < $1.value })?.key : model.hoverKey)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Token 用量").font(.system(size: 14, weight: .semibold))
                if model.official == nil { Text("仅本机").font(.system(size: 11)).foregroundColor(.secondary) }
                Spacer()
                Picker("", selection: $model.range) {
                    ForEach(TokenRange.allCases, id: \.self) { r in Text(r.title).tag(r) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            BarChart(bars: bars, active: active, axisKeys: Set(axisKeys(bars)), axisLabel: axisLabel, hover: $hover)
            .frame(height: 150)
        }
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

struct TooltipView: View {
    let bar: TokenBar

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bar.label)
            Text("\(Fmt.tokens(bar.value)) Tokens").fontWeight(.semibold)
            Text("官方统计（多端） \(Fmt.tokens(bar.official))")
            Text("本机 \(Fmt.tokens(bar.local))")
        }
        .font(.system(size: 11))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))

    }
}

/// 自绘柱状图（不用 Swift Charts：它在没有 GPU 的 Intel CI 机器上会触发 Metal 断言）。
struct BarChart: View {
    let bars: [TokenBar]
    let active: String?
    let axisKeys: Set<String>
    let axisLabel: (String) -> String
    @Binding var hover: String?

    private let axisWidth: CGFloat = 44
    private let labelHeight: CGFloat = 16

    var body: some View {
        let maxV = max(bars.map { $0.value }.max() ?? 0, 1)
        GeometryReader { geo in
            let plotW = geo.size.width - axisWidth
            let plotH = geo.size.height - labelHeight
            let slot = plotW / CGFloat(max(bars.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                    let y = plotH * (1 - f)
                    Path { p in p.move(to: CGPoint(x: axisWidth, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    Text(Fmt.tokens(Int64(Double(maxV) * f)))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .frame(width: axisWidth - 4, alignment: .trailing)
                        .position(x: (axisWidth - 4) / 2, y: min(max(y, 6), plotH - 6))
                }
                ForEach(Array(bars.enumerated()), id: \.element.key) { i, b in
                    let h = plotH * CGFloat(Double(b.value) / Double(maxV))
                    Rectangle()
                        .fill(b.key == active ? Color.orange : Color.orange.opacity(0.7))
                        .frame(width: max(slot * 0.62, 1), height: max(h, b.value > 0 ? 1 : 0))
                        .position(x: axisWidth + slot * (CGFloat(i) + 0.5), y: plotH - h / 2)
                    if axisKeys.contains(b.key) {
                        Text(axisLabel(b.key)).font(.system(size: 9)).foregroundColor(.secondary)
                            .fixedSize()
                            .position(x: axisWidth + slot * (CGFloat(i) + 0.5), y: plotH + labelHeight / 2 + 1)
                    }
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
                        .fixedSize()
                        .position(x: min(max(axisWidth + slot * (CGFloat(i) + 0.5), 90), geo.size.width - 90), y: 36)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
