import SwiftUI

/// 0.2.0 视觉数值（契约 §2）：亮 / 暗两套。
struct Theme {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    static let accent = Color(red: 0xF2 / 255, green: 0x78 / 255, blue: 0x0C / 255)
    static let accent2 = Color(red: 0xFF / 255, green: 0xA0 / 255, blue: 0x40 / 255)
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent2, accent], startPoint: .top, endPoint: .bottom)
    }
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)

    private func ov(_ light: Double, _ darkV: Double) -> Color {
        dark ? Color.white.opacity(darkV) : Color.black.opacity(light)
    }

    var ink: Color { dark ? Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255) : Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255) }
    var ink2: Color { ov(0.55, 0.55) }
    var ink3: Color { ov(0.35, 0.30) }
    var hover: Color { ov(0.06, 0.09) }
    var sel: Color { ov(0.07, 0.11) }
    var track: Color { ov(0.06, 0.08) }
    var line: Color { ov(0.10, 0.08) }
    var card: Color { Color.white.opacity(dark ? 0.06 : 0.62) }
    var segOn: Color { dark ? Color.white.opacity(0.14) : Color.white }
    var panelStroke: Color { ov(0.12, 0.14) }
    var tipBg: Color {
        dark ? Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255).opacity(0.96)
             : Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255).opacity(0.94)
    }
    var tipInk: Color { dark ? Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255) : .white }

    static func health(_ percent: Double) -> Color {
        switch QuotaLevel.of(remainingPercent: percent) {
        case .normal: return green
        case .critical: return red
        }
    }
}

extension View {
    /// 圆角 10 卡片：白 62% / 白 6%，0.5pt 描边。
    func card(_ th: Theme) -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(th.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(th.line, lineWidth: 0.5))
    }

    /// 悬停显示手型。
    func handCursor() -> some View {
        self.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// 只有上面两个角是圆角（柱顶 2pt）。
struct TopRounded: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 圆头进度条。
struct QuotaBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// 20pt 圆角橙底图标。
struct AppLogo: View {
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Theme.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "chart.bar.fill").font(.system(size: size * 0.55, weight: .semibold)).foregroundColor(.white))
    }
}

/// 反色小气泡：第一行半粗。
struct TipBubble: View {
    let lines: [String]
    var boldLine = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let th = Theme(scheme)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).fontWeight(i == boldLine ? .semibold : .regular).lineLimit(1)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundColor(th.tipInk)
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(th.tipBg))
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        .fixedSize()
    }
}

/// 按下缩到 0.94。
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
