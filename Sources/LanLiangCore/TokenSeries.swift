import Foundation

public enum TokenRange: String, CaseIterable, Codable {
    case daily, weekly, monthly

    public var title: String {
        switch self { case .daily: return "每日"; case .weekly: return "每周"; case .monthly: return "每月" }
    }
}

/// 柱状图的一根柱子。
public struct TokenBar: Equatable, Identifiable {
    public var id: String { key }
    public var key: String          // 起始日 yyyy-MM-dd
    public var start: Date
    public var label: String        // 悬停第一行：11月23日 / 11月17日–11月23日 / 2026年11月
    public var official: Int64
    public var local: Int64
    public var usesOfficial: Bool
    public var value: Int64 { usesOfficial ? official : local }
}

public enum TokenSeries {
    /// 周一开始的公历。
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        return c
    }

    static func md(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    /// official 为 nil 表示官方接口失败，柱高改用本机值。
    public static func bars(range: TokenRange, official: [String: Int64]?, local: [String: Int64],
                            now: Date, calendar cal: Calendar) -> [TokenBar] {
        let today = cal.startOfDay(for: now)
        var periods: [(start: Date, end: Date, label: String)] = []
        switch range {
        case .daily:
            for i in (0..<30).reversed() {
                let s = cal.date(byAdding: .day, value: -i, to: today)!
                periods.append((s, s, md(s, cal)))
            }
        case .weekly:
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
            for i in (0..<12).reversed() {
                let s = cal.date(byAdding: .day, value: -7 * i, to: thisWeek)!
                let e = cal.date(byAdding: .day, value: 6, to: s)!
                periods.append((s, e, "\(md(s, cal))–\(md(e, cal))"))
            }
        case .monthly:
            let thisMonth = cal.dateInterval(of: .month, for: today)!.start
            for i in (0..<6).reversed() {
                let s = cal.date(byAdding: .month, value: -i, to: thisMonth)!
                let e = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: 1, to: s)!)!
                let c = cal.dateComponents([.year, .month], from: s)
                periods.append((s, e, "\(c.year ?? 0)年\(c.month ?? 0)月"))
            }
        }
        return periods.map { p in
            var o: Int64 = 0, l: Int64 = 0
            var d = p.start
            while d <= p.end {
                let k = DayKey.of(d, calendar: cal)
                o += official?[k] ?? 0
                l += local[k] ?? 0
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            return TokenBar(key: DayKey.of(p.start, calendar: cal), start: p.start, label: p.label,
                            official: o, local: l, usesOfficial: official != nil)
        }
    }
}
