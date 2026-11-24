import Foundation

/// 宽松读数字：整数、小数或字符串数字都认。
func looseDouble(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
}

/// 认 ISO 8601（可带小数秒、可带时区偏移）或 Unix 秒。
public func parseFlexibleDate(_ v: Any?) -> Date? {
    if let s = v as? String {
        let t = s.trimmingCharacters(in: .whitespaces)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t) { return d }
        if let n = Double(t), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }
    if let n = looseDouble(v), n > 0 { return Date(timeIntervalSince1970: n) }
    return nil
}

/// `~/.codex/auth.json` 读出的内容（只读，不改写、不刷新）。
public enum CodexCredential: Equatable {
    case none
    case apiKey
    case oauth(accessToken: String, idToken: String?, accountID: String?)

    public static func parse(_ data: Data) -> CodexCredential {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .none }
        if let tokens = obj["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            let id = tokens["id_token"] as? String
            let acct = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .oauth(accessToken: access, idToken: id, accountID: acct)
        }
        if let key = obj["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKey }
        return .none
    }

    /// `CODEX_HOME` 优先，否则 `~/.codex`。
    public static func home(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = env["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

/// id_token 里的账号信息。
public struct CodexAccount: Equatable {
    public var email: String?
    public var planRaw: String?
    public var subscriptionUntil: Date?

    public init(email: String?, planRaw: String?, subscriptionUntil: Date?) {
        self.email = email; self.planRaw = planRaw; self.subscriptionUntil = subscriptionUntil
    }

    public static func from(idToken: String) -> CodexAccount? {
        guard let p = JWT.payload(idToken) else { return nil }
        let auth = p["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let profile = p["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        return CodexAccount(email: (p["email"] as? String) ?? (profile["email"] as? String),
                            planRaw: auth["chatgpt_plan_type"] as? String,
                            subscriptionUntil: parseFlexibleDate(auth["chatgpt_subscription_active_until"]))
    }
}

/// `wham/usage` 的额度窗口：按 limit_window_seconds 认周和 5 小时。
public struct CodexUsage: Equatable {
    public var planRaw: String?
    public var weekly: QuotaWindow?
    public var fiveHour: QuotaWindow?

    public static func parse(_ data: Data) -> CodexUsage? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any] else { return nil }
        var u = CodexUsage(planRaw: obj["plan_type"] as? String, weekly: nil, fiveHour: nil)
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any],
                  let used = looseDouble(w["used_percent"]),
                  let secs = looseDouble(w["limit_window_seconds"]) else { continue }
            let reset = looseDouble(w["reset_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let kind = WindowKind.from(windowSeconds: Int(secs))
            let win = QuotaWindow(kind: kind, remainingPercent: (100 - used).rounded(), resetsAt: reset)
            switch kind {
            case .weekly: u.weekly = win
            case .fiveHour: u.fiveHour = win
            case .other: break
            }
        }
        return u
    }
}

/// `wham/profiles/me` 的每日官方 Token（键 yyyy-MM-dd）。
public enum CodexProfile {
    public static func parseDaily(_ data: Data) -> [String: Int64]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stats = obj["stats"] as? [String: Any],
              let buckets = stats["daily_usage_buckets"] as? [[String: Any]] else { return nil }
        var out: [String: Int64] = [:]
        for b in buckets {
            guard let day = b["start_date"] as? String, let t = looseDouble(b["tokens"]), t >= 0 else { continue }
            out[day, default: 0] += Int64(t)
        }
        return out
    }
}

/// 本机会话日志：只累加 token_count 事件的 last_token_usage。
public enum CodexSessionLog {
    /// 解析一行；不是 token_count 或坏行返回 nil。
    public static func parseLine(_ line: Substring) -> (date: Date, tokens: Int64)? {
        guard line.contains("token_count"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let date = parseFlexibleDate(obj["timestamp"]) else { return nil }
        let total = looseDouble(last["total_tokens"])
            ?? ((looseDouble(last["input_tokens"]) ?? 0) + (looseDouble(last["output_tokens"]) ?? 0))
        guard total > 0 else { return nil }
        return (date, Int64(total))
    }

    /// 把一个文件内容按本地日期累加到 daily。
    public static func accumulate(_ text: String, into daily: inout [String: Int64], calendar: Calendar) {
        for line in text.split(separator: "\n") {
            if let (d, t) = parseLine(line) { daily[DayKey.of(d, calendar: calendar), default: 0] += t }
        }
    }
}

public enum DayKey {
    public static func of(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
