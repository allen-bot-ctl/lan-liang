import Foundation

/// Antigravity 登录凭证（钥匙串项或 ~/.gemini 文件里的 JSON）。栏量只读官方凭据，换新结果只写自己的缓存。
public struct GeminiCredential: Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiry: Date?
    public var idToken: String?
    /// 账号邮箱：缓存里存的，或从 id_token 读出来的。
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expiry: Date?, idToken: String?, email: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiry = expiry; self.idToken = idToken; self.email = email
    }

    public static let keychainPrefix = "go-keyring-base64:"
    public static let keychainHexPrefix = "go-keyring-encoded:"

    /// 钥匙串值解成 JSON 字节：`go-keyring-base64:`、`go-keyring-encoded:`（十六进制）、
    /// `security -w` 对非文本值打印的整段十六进制，或直接是 JSON。
    public static func decodeStoredValue(_ raw: Data) -> Data? {
        guard var text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if let bytes = hexBytes(text), let inner = String(data: bytes, encoding: .utf8) {
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let json: Data?
        if text.hasPrefix(keychainPrefix) {
            json = Data(base64Encoded: String(text.dropFirst(keychainPrefix.count)))
        } else if text.hasPrefix(keychainHexPrefix) {
            json = hexBytes(String(text.dropFirst(keychainHexPrefix.count)))
        } else {
            json = text.data(using: .utf8)
        }
        guard let d = json, d.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) == UInt8(ascii: "{")
        else { return nil }
        return d
    }

    static func hexBytes(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    public static func parse(_ raw: Data) -> GeminiCredential? {
        guard let data = decodeStoredValue(raw),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tok = obj["token"] as? [String: Any] else { return nil }
        let access = (tok["access_token"] as? String) ?? ""
        let refresh = (tok["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard !access.isEmpty || refresh != nil else { return nil }
        let id = (obj["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var email = (obj["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if email == nil, let id { email = JWT.payload(id)?["email"] as? String }
        return GeminiCredential(accessToken: access, refreshToken: refresh,
                                expiry: parseFlexibleDate(tok["expiry"]), idToken: id, email: email)
    }

    /// 没有到期时间当作已过期（换新一次就有了）。
    public func needsRefresh(now: Date, skew: TimeInterval) -> Bool {
        guard !accessToken.isEmpty, let e = expiry else { return true }
        return e.timeIntervalSince(now) <= skew
    }

    /// 访问令牌本身还能不能用（不考虑提前换新）。
    public func isUsable(now: Date) -> Bool {
        guard !accessToken.isEmpty else { return false }
        guard let e = expiry else { return false }
        return e > now
    }

    /// ~/.gemini 下的官方镜像文件，钥匙串读不到时按这个顺序读。
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
