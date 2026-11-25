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

    /// Token 数：<1万原样，≥1万用「万」，≥1亿用「亿」，两位小数。
    public static func tokens(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.2f万", Double(n) / 10_000) }
        return "\(n)"
    }

    /// 用量图纵轴刻度（契约 0.1.5 §3）：≥1 亿「x.xx亿」，≥1000 万不带小数「4450万」，其余同 tokens。
    public static func axisTokens(_ n: Int64) -> String {
        if n >= 100_000_000 { return tokens(n) }
        if n >= 10_000_000 { return "\(Int64((Double(n) / 10_000).rounded()))万" }
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
