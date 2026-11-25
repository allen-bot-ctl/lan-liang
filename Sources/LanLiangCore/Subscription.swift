import Foundation

/// Codex 订阅有效期（契约 0.1.2 §1）。
/// id_token 里的日期是令牌签发时的计费周期结束日；令牌不常换新，续费后它会落在过去，
/// 所以付费档要按 UTC 自然月推到当前周期末。拿不准时绝不显示「已过期」。
public enum CodexSubscription {
    public enum Tier: Equatable { case paid, free, unknown }

    /// 有效期行要显示的内容。
    public enum Line: Equatable {
        /// 有效期至 `until`；`daysLeft` = 向下取整的剩余天数，0 表示不到 1 天。
        case active(until: Date, daysLeft: Int)
        case expired
        case hidden
    }

    public static func tier(_ raw: String?) -> Tier {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return .unknown }
        if ["plus", "prolite", "pro-lite", "pro", "promax", "pro-max"].contains(r) { return .paid }
        if ["team", "business", "enterprise", "edu"].contains(where: { r.contains($0) }) { return .paid }
        if r == "free" { return .free }
        return .unknown
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 从 `raw` 起按 UTC 自然月往后推（锚定原始日，超出目标月就取月末），
    /// 返回第一个晚于 `now` 的日期；`raw` 本身在未来时原样返回；推 `maxSteps` 次还不够返回 nil。
    public static func currentPeriodEnd(raw: Date, now: Date, maxSteps: Int = 48) -> Date? {
        if raw > now { return raw }
        let cal = utc
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: raw)
        guard let y0 = c.year, let m0 = c.month, let d0 = c.day else { return nil }
        let frac = raw.timeIntervalSince1970 - floor(raw.timeIntervalSince1970)
        for k in 1...max(1, maxSteps) {
            let idx = (m0 - 1) + k
            let y = y0 + idx / 12, m = idx % 12 + 1
            guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
                  let days = cal.range(of: .day, in: .month, for: first)?.count,
                  let d = cal.date(from: DateComponents(year: y, month: m, day: min(d0, days),
                                                        hour: c.hour, minute: c.minute, second: c.second))
            else { return nil }
            let candidate = d.addingTimeInterval(frac)
            if candidate > now { return candidate }
        }
        return nil
    }

    /// - Parameters:
    ///   - raw: id_token（或 access_token）里的 chatgpt_subscription_active_until。
    ///   - planRaw: 套餐原始值：实时 wham/usage 的 plan_type，接口没成功时是 id_token 的 chatgpt_plan_type。
    ///   - planIsLive: planRaw 是否来自实时接口。
    public static func line(raw: Date?, planRaw: String?, planIsLive: Bool, now: Date) -> Line {
        guard let raw = raw else { return .hidden }
        func active(_ d: Date) -> Line { .active(until: d, daysLeft: max(0, Int(floor(d.timeIntervalSince(now) / 86_400)))) }
        if raw > now { return active(raw) }
        switch tier(planRaw) {
        case .paid:
            return currentPeriodEnd(raw: raw, now: now).map(active) ?? .hidden
        case .free:
            return planIsLive ? .expired : .hidden
        case .unknown:
            return .hidden
        }
    }

    /// 面板文案：「订阅有效期至 2026/12/12 · 剩 17 天」/「… · 剩不到 1 天」/「订阅已过期」；hidden 返回 nil。
    public static func text(_ line: Line, timeZone: TimeZone = .current) -> String? {
        switch line {
        case let .active(until, days):
            return "订阅有效期至 \(Fmt.day(until, timeZone: timeZone)) · " + (days == 0 ? "剩不到 1 天" : "剩 \(days) 天")
        case .expired: return "订阅已过期"
        case .hidden: return nil
        }
    }
}
