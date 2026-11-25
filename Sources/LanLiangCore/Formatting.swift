import Foundation

public enum Fmt {
    /// 邮箱打码：只留首字母和域名，如 a***@gmail.com。
    public static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else { return "***" }
        return "\(first)***@\(parts[1])"
    }

    /// Codex 套餐显示名（契约 §2）。
    public static func codexPlanName(_ raw: String?) -> String {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return "未知" }
        switch r {
        case "plus": return "Plus"
        case "prolite", "pro-lite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax", "pro-max": return "Pro 500"
        case "free": return "Free"
        default: break
        }
        for (key, name) in [("team", "Team"), ("business", "Business"), ("enterprise", "Enterprise"), ("edu", "Edu")]
        where r.contains(key) { return name }
        return raw!
    }

    /// Token 数：<1万原样，≥1万用「万」，≥1亿用「亿」，两位小数；末尾正好是「.00」时省略（契约 0.3.2 §5）：
    /// 「2100万」「3亿」「3.35亿」「3.50亿」「1.23万」。
    public static func tokens(_ n: Int64) -> String {
        func trim(_ s: String) -> String { s.hasSuffix(".00") ? String(s.dropLast(3)) : s }
        if n >= 100_000_000 { return trim(String(format: "%.2f", Double(n) / 100_000_000)) + "亿" }
        if n >= 10_000 {
            let w = String(format: "%.2f", Double(n) / 10_000)
            // 四舍五入后到了 10000万（如 99_999_999），进位成「亿」：「1亿」，不写「10000万」。
            if (Double(w) ?? 0) >= 10_000 { return trim(String(format: "%.2f", Double(n) / 100_000_000)) + "亿" }
            return trim(w) + "万"
        }
        return "\(n)"
    }

    /// 用量图纵轴刻度（契约 0.1.5 §3）：≥1 亿「x.xx亿」，≥1000 万不带小数「4450万」，其余同 tokens。
    public static func axisTokens(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }   // 刻度规则不变（0.3.2）
        if n >= 10_000_000 {
            let w = Int64((Double(n) / 10_000).rounded())
            // 取整后到了 10000万，进位成「亿」，按刻度的亿格式写「1.00亿」。
            if w >= 10_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }
            return "\(w)万"
        }
        return tokens(n)
    }

    /// 倒计时：X天X小时 / X小时X分 / X分。
    public static func countdown(from now: Date, to end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分"
    }

    /// 日期 yyyy/MM/dd（本地时区）。
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
