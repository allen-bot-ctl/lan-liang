#if canImport(AppKit)
import AppKit
import CoreText

/// 唯一一个菜单栏状态项的内容图（契约 0.1.2 §2，方案 B；0.3.2 改版）。
/// 每行三列：图标 | 周剩余（labelColor，左对齐紧贴图标）| 0.5pt 竖线 | 5 小时剩余（品牌橙半粗）；
/// 没有 5 小时窗口时写灰色「--」。0.3.2 起不是模板图（要画橙色），颜色按菜单栏当前外观解析；外观变了由调用方重画。
/// 宽度按实际文字量（PM 04:52 定：不按「100%」补齐，位数变了宽度跟着变）；两行时按较宽的一行对齐。
public enum MenuBarLayout {
    public struct Style {
        public var iconPoint: CGFloat
        public var iconColumn: CGFloat
        public var primaryFont: NSFont
        public var secondaryFont: NSFont
        public var gapAfterIcon: CGFloat
        /// 周剩余列和竖线之间、竖线和 5 小时列之间的空隙（0.3.2）。
        public var gapAroundDivider: CGFloat
        /// 竖线高度（契约 0.3.2 §2：两行每行 7pt，单行 11pt）。
        public var dividerHeight: CGFloat
        /// 「--」占位用常规字重（5 小时数字是半粗）。
        public var placeholderFont: NSFont {
            .monospacedDigitSystemFont(ofSize: secondaryFont.pointSize, weight: .regular)
        }
    }

    /// 两行：图标 8pt（列 9）、周剩余 9.5pt semibold、5 小时 8.5pt semibold；图标后 1.5、线两侧各 3。
    public static let compact = Style(iconPoint: 8, iconColumn: 9,
                                      primaryFont: .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                                      secondaryFont: .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
                                      gapAfterIcon: 1.5, gapAroundDivider: 3, dividerHeight: 7)
    /// 单行：照 0.1.1，周剩余 12pt、5 小时 10pt；图标 13pt（列 13）、图标后 2、线两侧各 3。
    public static let single = Style(iconPoint: 13, iconColumn: 13,
                                     primaryFont: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                     secondaryFont: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                                     gapAfterIcon: 2, gapAroundDivider: 3, dividerHeight: 11)

    /// 只开一个服务时的放大单行（契约 0.3.0 §2）：图标 15pt（列 15）、周剩余 14pt 半粗、5 小时 11pt 半粗。
    public static let large = Style(iconPoint: 15, iconColumn: 15,
                                    primaryFont: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                                    secondaryFont: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                    gapAfterIcon: 2, gapAroundDivider: 3, dividerHeight: 11)

    /// 竖线 0.5pt（Retina 下 1 像素），主文字色 35%。
    public static let dividerWidth: CGFloat = 0.5
    public static let dividerAlpha: CGFloat = 0.35
    /// 没有 5 小时窗口时的占位，主文字色 50%。
    public static let placeholder = "--"
    public static let placeholderAlpha: CGFloat = 0.5

    /// 5 小时剩余用品牌橙（契约 0.3.2 §3）：深色菜单栏 #FF9F0A，浅色菜单栏 #C25400。
    public static func secondaryColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
             : NSColor(srgbRed: 0xC2 / 255, green: 0x54 / 255, blue: 0x00 / 255, alpha: 1)
    }

    /// 第三列显示的文字：有 5 小时就是数字，没有就是「--」。
    public static func secondaryText(_ row: MenuBarGroup) -> (text: String, isPlaceholder: Bool) {
        if let s = row.secondary { return (s, false) }
        return (placeholder, true)
    }

    /// 调试/截图用：「77%|--」。
    public static func cellText(_ row: MenuBarGroup) -> String { "\(row.primary)|\(secondaryText(row).text)" }

    static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: f]).size().width)
    }

    /// large = 只开了一个服务：用放大单行（两行时不放大）。
    public static func style(rowCount: Int, large: Bool = false) -> Style {
        rowCount >= 2 ? compact : (large ? Self.large : single)
    }

    /// 第三列这一格的字体：5 小时数字半粗，「--」常规。
    static func secondaryFont(_ row: MenuBarGroup, _ st: Style) -> NSFont {
        secondaryText(row).isPlaceholder ? st.placeholderFont : st.secondaryFont
    }

    /// 各列宽度：图标列、周剩余列、5 小时列——都按这几行的实际文字取最宽（不再按「100%」「100」补齐）。
    public static func columns(_ rows: [MenuBarGroup], large: Bool = false) -> (icon: CGFloat, primary: CGFloat, secondary: CGFloat) {
        let st = style(rowCount: rows.count, large: large)
        let p = rows.map { textWidth($0.primary, st.primaryFont) }.max() ?? 0
        let s = rows.map { textWidth(secondaryText($0).text, secondaryFont($0, st)) }.max() ?? 0
        return (st.iconColumn, p, s)
    }

    /// 各列的 x（左对齐起点）：周剩余、竖线中心、5 小时。
    public static func positions(_ rows: [MenuBarGroup], large: Bool = false) -> (primary: CGFloat, divider: CGFloat, secondary: CGFloat) {
        let st = style(rowCount: rows.count, large: large)
        let c = columns(rows, large: large)
        let p = c.icon + st.gapAfterIcon
        let d = p + c.primary + st.gapAroundDivider + dividerWidth / 2
        let sx = d + dividerWidth / 2 + st.gapAroundDivider
        return (p, d, sx)
    }

    /// 内容宽度（点）；rows 为空时返回 0（由调用方显示栏量图标）。
    public static func width(_ rows: [MenuBarGroup], large: Bool = false) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        return positions(rows, large: large).secondary + columns(rows, large: large).secondary
    }

    /// 某一行文字的基线 y（非翻转坐标）：周剩余和 5 小时共用；给单测核对对齐用。
    public static func baseline(rowIndex i: Int, rowCount: Int, height: CGFloat, large: Bool = false) -> CGFloat {
        let st = style(rowCount: rowCount, large: large)
        let pitch: CGFloat = rowCount == 2 ? 10.5 : 0
        let cy = height / 2 + (rowCount == 2 ? (i == 0 ? pitch / 2 : -pitch / 2) : 0)
        return (cy - st.primaryFont.capHeight / 2).rounded()
    }

    public static func iconName(_ s: Service) -> String { s == .codex ? "terminal" : "sparkle" }

    /// 画出内容图；height 用菜单栏高度（NSStatusBar.system.thickness）。
    /// appearance：菜单栏按钮的 effectiveAppearance（nil = 当前外观）；颜色在画的时候按它解析。
    public static func image(_ rows: [MenuBarGroup], height: CGFloat, large: Bool = false,
                             appearance: NSAppearance? = nil) -> NSImage? {
        let rows = Array(rows.prefix(2))
        guard !rows.isEmpty else { return nil }
        let st = style(rowCount: rows.count, large: large)
        let pos = positions(rows, large: large)
        let c = columns(rows, large: large)
        let w = width(rows, large: large)
        let img = NSImage(size: NSSize(width: w, height: height), flipped: false) { _ in
            let ap = appearance ?? NSAppearance.currentDrawing()
            ap.performAsCurrentDrawingAppearance {
                let dark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // 动态色在当前外观下解析成固定颜色。
                let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? (dark ? .white : .black)
                let orange = secondaryColor(dark: dark)
                let pitch: CGFloat = rows.count == 2 ? 10.5 : 0
                for (i, row) in rows.enumerated() {
                    // 行中心：两行时上下各偏 pitch/2，整体在菜单栏高度内居中。
                    let cy = height / 2 + (rows.count == 2 ? (i == 0 ? pitch / 2 : -pitch / 2) : 0)
                    let config = NSImage.SymbolConfiguration(pointSize: st.iconPoint, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [label]))
                    if let sym = NSImage(systemSymbolName: iconName(row.service), accessibilityDescription: row.service.title)?
                        .withSymbolConfiguration(config) {
                        let s = sym.size
                        let r = NSRect(x: (c.icon - s.width) / 2, y: cy - s.height / 2, width: s.width, height: s.height)
                        sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    }
                    // 同一行的周剩余和 5 小时数字共用一条基线（按周剩余字体让数字视觉居中，契约 0.1.3 §3）。
                    let base = MenuBarLayout.baseline(rowIndex: i, rowCount: rows.count, height: height, large: large)
                    func draw(_ text: String, font: NSFont, x: CGFloat, color: NSColor) {
                        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                        let a = NSAttributedString(string: text, attributes: [
                            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
                        let line = CTLineCreateWithAttributedString(a)
                        ctx.saveGState()
                        ctx.setFillColor(color.cgColor)
                        ctx.textMatrix = .identity
                        ctx.textPosition = CGPoint(x: x, y: base)
                        CTLineDraw(line, ctx)
                        ctx.restoreGState()
                    }
                    // 周剩余左对齐，紧跟图标（0.3.2：图标和数字之间不再空一位）。
                    draw(row.primary, font: st.primaryFont, x: pos.primary, color: label)
                    // 0.5pt 竖线，和数字垂直居中。
                    let lh = st.dividerHeight
                    let dy = base + st.primaryFont.capHeight / 2 - lh / 2
                    label.withAlphaComponent(dividerAlpha).setFill()
                    NSRect(x: pos.divider - dividerWidth / 2, y: dy, width: dividerWidth, height: lh).fill()
                    let sec = secondaryText(row)
                    draw(sec.text, font: secondaryFont(row, st), x: pos.secondary,
                         color: sec.isPlaceholder ? label.withAlphaComponent(placeholderAlpha) : orange)
                }
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = rows.map { "\($0.service.title) \($0.primary) 5小时 \($0.secondary ?? "无")" }
            .joined(separator: "，")
        return img
    }
}
#endif
