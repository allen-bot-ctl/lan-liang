#if canImport(AppKit)
import AppKit

/// 唯一一个菜单栏状态项的内容图（契约 0.1.2 §2，方案 B）。
/// 整张图是模板图：周剩余不透明（显示成 labelColor），5 小时剩余半透明（显示成浅色），
/// 系统按菜单栏深浅色着色。宽度只按「100%」「100」这些最长文案定，数字变化不跳。
public enum MenuBarLayout {
    public struct Style {
        public var iconPoint: CGFloat
        public var iconColumn: CGFloat
        public var primaryFont: NSFont
        public var secondaryFont: NSFont
        public var gapAfterIcon: CGFloat
        public var gapBeforeSecondary: CGFloat
    }

    /// 两行：图标约 9pt、周剩余 9.5pt semibold、5 小时 8.5pt。
    public static let compact = Style(iconPoint: 8, iconColumn: 10,
                                      primaryFont: .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                                      secondaryFont: .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                                      gapAfterIcon: 2, gapBeforeSecondary: 3)
    /// 单行：照 0.1.1，周剩余 12pt、5 小时 10pt。
    public static let single = Style(iconPoint: 13, iconColumn: 16,
                                     primaryFont: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                     secondaryFont: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                     gapAfterIcon: 3, gapBeforeSecondary: 4)

    /// 5 小时剩余的不透明度（模板图里显示成 secondaryLabelColor 那样的浅色）。
    public static let secondaryAlpha: CGFloat = 0.55

    static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: f]).size().width)
    }

    public static func style(rowCount: Int) -> Style { rowCount >= 2 ? compact : single }

    /// 各列宽度：图标列、周剩余列（按「100%」）、5 小时列（按「100」，任一行有 5 小时才留）。
    public static func columns(_ rows: [MenuBarGroup]) -> (icon: CGFloat, primary: CGFloat, secondary: CGFloat) {
        let st = style(rowCount: rows.count)
        let p = rows.map { textWidth($0.primary, st.primaryFont) }.reduce(textWidth("100%", st.primaryFont), max)
        let hasSecondary = rows.contains { $0.secondary != nil }
        let s = hasSecondary ? rows.compactMap { $0.secondary.map { textWidth($0, st.secondaryFont) } }
            .reduce(textWidth("100", st.secondaryFont), max) : 0
        return (st.iconColumn, p, s)
    }

    /// 内容宽度（点）；rows 为空时返回 0（由调用方显示栏量图标）。
    public static func width(_ rows: [MenuBarGroup]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let st = style(rowCount: rows.count)
        let c = columns(rows)
        return c.icon + st.gapAfterIcon + c.primary + (c.secondary > 0 ? st.gapBeforeSecondary + c.secondary : 0)
    }

    public static func iconName(_ s: Service) -> String { s == .codex ? "terminal" : "sparkle" }

    /// 画出内容图；height 用菜单栏高度（NSStatusBar.system.thickness）。
    public static func image(_ rows: [MenuBarGroup], height: CGFloat) -> NSImage? {
        let rows = Array(rows.prefix(2))
        guard !rows.isEmpty else { return nil }
        let st = style(rowCount: rows.count)
        let c = columns(rows)
        let w = width(rows)
        let img = NSImage(size: NSSize(width: w, height: height), flipped: false) { _ in
            let pitch: CGFloat = rows.count == 2 ? 10.5 : 0
            for (i, row) in rows.enumerated() {
                // 行中心：两行时上下各偏 pitch/2，整体在菜单栏高度内居中。
                let cy = height / 2 + (rows.count == 2 ? (i == 0 ? pitch / 2 : -pitch / 2) : 0)
                if let sym = NSImage(systemSymbolName: iconName(row.service), accessibilityDescription: row.service.title)?
                    .withSymbolConfiguration(.init(pointSize: st.iconPoint, weight: .semibold)) {
                    let s = sym.size
                    let r = NSRect(x: (c.icon - s.width) / 2, y: cy - s.height / 2, width: s.width, height: s.height)
                    sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                }
                func draw(_ text: String, font: NSFont, right: CGFloat, alpha: CGFloat) {
                    let a = NSAttributedString(string: text, attributes: [
                        .font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
                    let tw = a.size().width
                    // 数字视觉中心（基线 + 大写高度一半）对准行中心。
                    let baseline = cy - font.capHeight / 2
                    a.draw(at: NSPoint(x: right - tw, y: baseline + font.descender))
                }
                let pRight = c.icon + st.gapAfterIcon + c.primary
                draw(row.primary, font: st.primaryFont, right: pRight, alpha: 1)
                if let sec = row.secondary {
                    draw(sec, font: st.secondaryFont, right: pRight + st.gapBeforeSecondary + c.secondary, alpha: secondaryAlpha)
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = rows.map { "\($0.service.title) \($0.primary)\($0.secondary.map { " 5小时 " + $0 } ?? "")" }
            .joined(separator: "，")
        return img
    }
}
#endif
