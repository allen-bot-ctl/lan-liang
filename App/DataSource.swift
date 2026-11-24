import Foundation
import Security

struct RefreshResult {
    var codex: ServiceSnapshot
    var gemini: ServiceSnapshot
    var official: [String: Int64]?
    var local: [String: Int64]
    var now: Date?
}

/// 数据来源：真实（读本机登录 + 调接口）或模拟（LANLIANG_FAKE / --debug-fake）。
protocol DataSource: AnyObject {
    func refresh(current: (ServiceSnapshot, ServiceSnapshot), completion: @escaping (RefreshResult) -> Void)
    func loadSync(into model: PanelModel)
    func allowKeychainAgain()
}

func makeDataSource() -> DataSource {
    if let p = argValue("debug-fake") ?? ProcessInfo.processInfo.environment["LANLIANG_FAKE"], !p.isEmpty {
        return FakeSource(path: p)
    }
    return LiveSource()
}

// MARK: - 模拟数据

final class FakeSource: DataSource {
    let path: String
    init(path: String) { self.path = path }

    private func load() -> RefreshResult {
        guard let d = FileManager.default.contents(atPath: path), let f = try? FakeData.decode(d) else {
            print("DEBUG_FAKE error path=\(path)")
            return RefreshResult(codex: .init(status: .fetchFailed), gemini: .init(status: .fetchFailed),
                                 official: nil, local: [:], now: nil)
        }
        return RefreshResult(codex: f.codex, gemini: f.gemini, official: f.official, local: f.local, now: f.now)
    }

    func refresh(current: (ServiceSnapshot, ServiceSnapshot), completion: @escaping (RefreshResult) -> Void) {
        let r = load()
        DispatchQueue.main.async { completion(r) }
    }

    func loadSync(into model: PanelModel) {
        let r = load()
        model.codex = r.codex; model.gemini = r.gemini; model.official = r.official; model.local = r.local
        if let n = r.now { model.now = { n } }
    }

    func allowKeychainAgain() {}
}

// MARK: - 真实数据（只读：不写 ~/.codex、~/.gemini、钥匙串）

enum HTTPFailure: Error { case unauthorized, failed }

private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

private func send(_ req: URLRequest) async throws -> Data {
    var r = req
    r.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || code == 403 { throw HTTPFailure.unauthorized }
    guard (200..<300).contains(code) else { throw HTTPFailure.failed }
    return data
}

final class LiveSource: DataSource {
    private let codex = CodexLive()
    private let gemini = GeminiLive()

    func refresh(current: (ServiceSnapshot, ServiceSnapshot), completion: @escaping (RefreshResult) -> Void) {
        Task.detached {
            async let c = self.codex.fetch(previous: current.0)
            async let g = self.gemini.fetch(previous: current.1)
            let (cr, gr) = await (c, g)
            let r = RefreshResult(codex: cr.snapshot, gemini: gr, official: cr.official, local: cr.local, now: nil)
            await MainActor.run { completion(r) }
        }
    }

    func loadSync(into model: PanelModel) {}
    func allowKeychainAgain() { gemini.allowKeychainAgain() }
}

// MARK: Codex

final class CodexLive {
    private var scanCache: [String: (mtime: Date, daily: [String: Int64])] = [:]
    private let lock = NSLock()

    struct Output { var snapshot: ServiceSnapshot; var official: [String: Int64]?; var local: [String: Int64] }

    func fetch(previous: ServiceSnapshot) async -> Output {
        let home = CodexCredential.home()
        let local = scanLocal(home: home)
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("auth.json").path) else {
            return Output(snapshot: .init(status: .notLoggedIn), official: nil, local: local)
        }
        switch CodexCredential.parse(data) {
        case .none:
            return Output(snapshot: .init(status: .notLoggedIn), official: nil, local: local)
        case .apiKey:
            return Output(snapshot: .init(status: .apiKeyOnly), official: nil, local: local)
        case let .oauth(access, idToken, accountID):
            let acct = idToken.flatMap { CodexAccount.from(idToken: $0) }
            var snap = ServiceSnapshot(status: .ok, email: acct?.email,
                                       plan: acct?.planRaw.map { Fmt.codexPlanName($0) },
                                       subscriptionUntil: acct?.subscriptionUntil,
                                       weekly: previous.weekly, fiveHour: previous.fiveHour)
            func request(_ path: String) -> URLRequest {
                var r = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/" + path)!)
                r.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
                r.setValue("application/json", forHTTPHeaderField: "Accept")
                r.setValue("LanLiang/\(appVersion)", forHTTPHeaderField: "User-Agent")
                if let a = accountID { r.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
                return r
            }
            do {
                let d = try await send(request("wham/usage"))
                if let u = CodexUsage.parse(d) {
                    snap.weekly = u.weekly
                    snap.fiveHour = u.fiveHour
                    if snap.plan == nil, let p = u.planRaw { snap.plan = Fmt.codexPlanName(p) }
                } else {
                    snap.status = .fetchFailed
                }
            } catch HTTPFailure.unauthorized {
                snap.status = .loginExpired
            } catch {
                snap.status = .fetchFailed
            }
            var official: [String: Int64]?
            if snap.status != .loginExpired, let d = try? await send(request("wham/profiles/me")) {
                official = CodexProfile.parseDaily(d)
            }
            return Output(snapshot: snap, official: official, local: local)
        }
    }

    /// 扫 sessions 与 archived_sessions 下的 .jsonl；文件修改时间没变就用缓存。
    private func scanLocal(home: URL) -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let cal = TokenSeries.calendar()
        var seen = Set<String>()
        for folder in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(folder)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let path = url.path
                seen.insert(path)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let c = scanCache[path], c.mtime == mtime { continue }
                var daily: [String: Int64] = [:]
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    CodexSessionLog.accumulate(text, into: &daily, calendar: cal)
                }
                scanCache[path] = (mtime, daily)
            }
        }
        scanCache = scanCache.filter { seen.contains($0.key) }
        var total: [String: Int64] = [:]
        for (_, c) in scanCache { for (k, v) in c.daily { total[k, default: 0] += v } }
        return total
    }
}

// MARK: Gemini（Antigravity 登录）

/// Antigravity 桌面端的公开 OAuth 客户端；secret 待 PM 确认来源后填入，空时不换新令牌（显示登录过期）。
enum AntigravityOAuth {
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = ""
}

final class GeminiLive {
    private let keychainQueue = DispatchQueue(label: "lanliang.keychain")
    private var keychainDenied = false
    private var keychainBusy = false
    /// 内存里换新的令牌（按 refresh_token 区分），不写回任何地方。
    private var refreshed: (refreshToken: String, access: String, expiry: Date)?
    private let lock = NSLock()

    func allowKeychainAgain() { lock.lock(); keychainDenied = false; lock.unlock() }

    private enum CredResult { case found(GeminiCredential), none, denied, busy }

    private func readCredential() -> CredResult {
        for f in GeminiCredential.candidateFiles() {
            if let d = FileManager.default.contents(atPath: f.path), let c = GeminiCredential.parse(d) { return .found(c) }
        }
        lock.lock()
        if keychainDenied { lock.unlock(); return .denied }
        if keychainBusy { lock.unlock(); return .busy }
        keychainBusy = true
        lock.unlock()
        defer { lock.lock(); keychainBusy = false; lock.unlock() }
        return keychainQueue.sync { () -> CredResult in
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "gemini",
                                    kSecAttrAccount as String: "antigravity",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &out)
            switch st {
            case errSecSuccess:
                if let d = out as? Data, let c = GeminiCredential.parse(d) { return .found(c) }
                return .none
            case errSecItemNotFound:
                return .none
            default:
                lock.lock(); keychainDenied = true; lock.unlock()
                return .denied
            }
        }
    }

    private var ideVersion: String {
        let plist = "/Applications/Antigravity.app/Contents/Info.plist"
        let v = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String) ?? ""
        return v.compare("2.25.0", options: .numeric) == .orderedAscending ? "2.25.0" : v
    }

    private var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private func accessToken(_ c: GeminiCredential) async throws -> String {
        if !c.isExpired(now: Date()) { return c.accessToken }
        guard let rt = c.refreshToken, !rt.isEmpty else { throw HTTPFailure.unauthorized }
        lock.lock(); let cached = refreshed; lock.unlock()
        if let r = cached, r.refreshToken == rt, r.expiry.timeIntervalSinceNow > 60 { return r.access }
        guard !AntigravityOAuth.clientSecret.isEmpty else { throw HTTPFailure.unauthorized }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: rt),
                           .init(name: "client_id", value: AntigravityOAuth.clientID),
                           .init(name: "client_secret", value: AntigravityOAuth.clientSecret)]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let d: Data
        do { d = try await send(req) } catch { throw HTTPFailure.unauthorized }
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let at = obj["access_token"] as? String else { throw HTTPFailure.unauthorized }
        let exp = Date().addingTimeInterval((obj["expires_in"] as? Double) ?? 3_600)
        lock.lock(); refreshed = (rt, at, exp); lock.unlock()
        return at
    }

    private func post(_ method: String, token: String, ua: String, body: [String: Any]) async throws -> Data {
        var r = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:" + method)!)
        r.httpMethod = "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(r)
    }

    func fetch(previous: ServiceSnapshot) async -> ServiceSnapshot {
        let cred: GeminiCredential
        switch readCredential() {
        case .found(let c): cred = c
        case .none: return .init(status: .notLoggedIn)
        case .denied: return .init(status: .keychainDenied)
        case .busy: return previous
        }
        var snap = previous
        snap.status = .ok
        if let id = cred.idToken, let email = JWT.payload(id)?["email"] as? String { snap.email = email }
        do {
            let token = try await accessToken(cred)
            let v = ideVersion
            let meta: [String: Any] = ["ideName": "antigravity", "ideType": "ANTIGRAVITY", "ideVersion": v,
                                       "pluginType": "GEMINI", "updateChannel": "stable"]
            let assistData = try await post("loadCodeAssist", token: token, ua: "antigravity/\(v) darwin/\(arch)",
                                            body: ["metadata": meta, "mode": "FULL_ELIGIBILITY_CHECK"])
            let assist = GeminiAssist.parse(assistData)
            if let p = assist?.planName { snap.plan = p }
            if snap.email == nil {
                var r = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
                r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                if let d = try? await send(r), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    snap.email = o["email"] as? String
                }
            }
            guard let project = assist?.project else { snap.status = .fetchFailed; return snap }
            let q = try await post("retrieveUserQuotaSummary", token: token,
                                   ua: "antigravity/hub/\(v) (aidev_client; os_type=darwin; arch=\(arch))",
                                   body: ["project": project])
            if let parsed = GeminiQuota.parse(q) {
                snap.weekly = parsed.weekly
                snap.fiveHour = parsed.fiveHour
            } else {
                snap.status = .fetchFailed
            }
        } catch HTTPFailure.unauthorized {
            snap.status = .loginExpired
        } catch {
            snap.status = .fetchFailed
        }
        return snap
    }
}
