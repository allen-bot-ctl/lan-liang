import Foundation

/// Antigravity 登录凭证（文件或钥匙串里的 JSON）。只读，换新令牌只放内存。
public struct GeminiCredential: Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiry: Date?
    public var idToken: String?

    public static let keychainPrefix = "go-keyring-base64:"

    /// 钥匙串的值可能带 `go-keyring-base64:` 前缀。
    public static func parse(_ raw: Data) -> GeminiCredential? {
        var data = raw
        if let s = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.hasPrefix(keychainPrefix) {
            guard let d = Data(base64Encoded: String(s.dropFirst(keychainPrefix.count))) else { return nil }
            data = d
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tok = obj["token"] as? [String: Any],
              let access = tok["access_token"] as? String else { return nil }
        return GeminiCredential(accessToken: access, refreshToken: tok["refresh_token"] as? String,
                                expiry: parseFlexibleDate(tok["expiry"]), idToken: obj["id_token"] as? String)
    }

    public func isExpired(now: Date, skew: TimeInterval = 60) -> Bool {
        guard let e = expiry else { return false }
        return e.timeIntervalSince(now) <= skew
    }

    /// 文件读取顺序（先文件后钥匙串）。
    public static func candidateFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let g = home.appendingPathComponent(".gemini")
        return [g.appendingPathComponent("jetski-standalone-oauth-token"),
                g.appendingPathComponent("antigravity-cli/antigravity-oauth-token")]
    }
}

/// loadCodeAssist：套餐名与 project。
public struct GeminiAssist: Equatable {
    public var planName: String?
    public var project: String?

    public static func tierName(_ tier: [String: Any]?) -> String? {
        guard let t = tier else { return nil }
        if let n = t["name"] as? String, !n.isEmpty { return n }
        guard let id = t["id"] as? String, !id.isEmpty else { return nil }
        switch id {
        case "g1-pro-tier": return "Pro"
        case "g1-ultra-tier": return "Ultra"
        case "free-tier": return "Free"
        case "standard-tier": return "Standard"
        default: return id
        }
    }

    public static func parse(_ data: Data) -> GeminiAssist? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let plan = tierName(obj["paidTier"] as? [String: Any]) ?? tierName(obj["currentTier"] as? [String: Any])
        var project: String?
        if let s = obj["cloudaicompanionProject"] as? String { project = s }
        else if let o = obj["cloudaicompanionProject"] as? [String: Any] { project = o["id"] as? String }
        if project?.isEmpty == true { project = nil }
        return GeminiAssist(planName: plan, project: project)
    }
}

/// retrieveUserQuotaSummary：只取 Gemini 家族的周与 5 小时桶；remainingFraction 缺失 = 0%。
public enum GeminiQuota {
    static let weeklyIDs: Set<String> = ["gemini-weekly", "gemini:weekly"]
    static let fiveHourIDs: Set<String> = ["gemini-5h", "gemini:5h"]

    public static func parse(_ data: Data) -> (weekly: QuotaWindow?, fiveHour: QuotaWindow?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var buckets: [[String: Any]] = (obj["buckets"] as? [[String: Any]]) ?? []
        for g in (obj["groups"] as? [[String: Any]]) ?? [] { buckets += (g["buckets"] as? [[String: Any]]) ?? [] }
        var weekly: QuotaWindow?, five: QuotaWindow?
        for b in buckets {
            guard let id = b["bucketId"] as? String else { continue }
            let pct = ((looseDouble(b["remainingFraction"]) ?? 0) * 100).rounded()
            let reset = parseFlexibleDate(b["resetTime"])
            if weeklyIDs.contains(id) { weekly = QuotaWindow(kind: .weekly, remainingPercent: pct, resetsAt: reset) }
            if fiveHourIDs.contains(id) { five = QuotaWindow(kind: .fiveHour, remainingPercent: pct, resetsAt: reset) }
        }
        return (weekly, five)
    }
}
