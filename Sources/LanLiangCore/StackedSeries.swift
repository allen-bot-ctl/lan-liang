import Foundation

/// 设置窗口消耗汇总的堆叠柱（0.3.1）：Codex 在下、Gemini 在上，区间划分和面板柱状图完全一样。
public struct StackedBar: Equatable {
    public var bar: TokenBar
    public var codex: Int64
    public var gemini: Int64
    public var total: Int64 { codex + gemini }
}

public enum StackedSeries {
    /// - Parameters:
    ///   - codex: Codex 官方每日用量；nil = 关掉、加载中或失败，这一段不画。
    ///   - gemini: Gemini 本机每日用量；nil 同上。
    /// - Returns: 每根柱子的 TokenBar（value = 两段合计，给坐标轴和悬停用）和两段各自的值。
    public static func bars(range: TokenRange, codex: [String: Int64]?, gemini: [String: Int64]?,
                            now: Date, calendar: Calendar) -> [StackedBar] {
        let c = TokenSeries.bars(range: range, official: nil, local: codex ?? [:], now: now, calendar: calendar)
        let g = TokenSeries.bars(range: range, official: nil, local: gemini ?? [:], now: now, calendar: calendar)
        return zip(c, g).map { cb, gb in
            var b = cb
            b.local = cb.local + gb.local
            return StackedBar(bar: b, codex: cb.local, gemini: gb.local)
        }
    }

    /// 悬停气泡四行（契约 0.3.1 §2）：日期（区间）、「Codex 2.86亿」、「Gemini 6600.00万」、「合计 3.52亿 Tokens」。
    public static func tipLines(_ s: StackedBar) -> [String] {
        [s.bar.label, "Codex \(Fmt.tokens(s.codex))", "Gemini \(Fmt.tokens(s.gemini))", "合计 \(Fmt.tokens(s.total)) Tokens"]
    }

    /// 纵轴最大值：各柱合计的最大值（至少 1，和面板一样）。
    public static func axisMax(_ bars: [StackedBar]) -> Int64 { max(bars.map { $0.total }.max() ?? 0, 1) }
}
