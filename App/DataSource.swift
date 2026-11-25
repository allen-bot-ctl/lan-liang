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
    /// Gemini 本机 Token 历史：后台串行扫描，结果回主线程；扫描还在跑时不再新起。
    func refreshGeminiHistory(completion: @escaping (GeminiHistory) -> Void)
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

    func refreshGeminiHistory(completion: @escaping (GeminiHistory) -> Void) {
        guard let d = FileManager.default.contents(atPath: path), let f = try? FakeData.decode(d),
              let h = f.geminiHistory else { return }
        DispatchQueue.main.async { completion(h) }
    }
}

// MARK: - 真实数据（只读 ~/.codex、~/.gemini、钥匙串；只写自己的 ~/.lanliang）

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

    /// 扫描受 QoS 影响很大（老板 Mac：后台 QoS 下 SQLite 读取 20.9 秒，正常 1.5 秒），用 userInitiated。
    private let historyQueue = DispatchQueue(label: "lanliang.gemini-history", qos: .userInitiated)
    private lazy var historyScanner: GeminiHistoryScanner = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GeminiHistoryScanner(home: home, cacheURL: GeminiUsageCacheFile.url(home: home))
    }()
    /// 只在主线程读写。
    private var historyBusy = false
    private var historyStarted = false

    func refreshGeminiHistory(completion: @escaping (GeminiHistory) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !historyBusy else { return }
        historyBusy = true
        let first = !historyStarted
        historyStarted = true
        historyQueue.async { [weak self] in
            guard let self = self else { return }
            // 启动时先用磁盘缓存立即出图，再扫描变过的对话。
            if first, let cached = self.historyScanner.loadDiskCache() {
                DispatchQueue.main.async { completion(cached) }
            }
            let r = self.historyScanner.scan()
            DispatchQueue.main.async {
                self.historyBusy = false
                completion(r)
            }
        }
    }

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
            // 套餐先用 id_token 的，wham/usage 成功后换成实时 plan_type；日期缺失时用 access_token 的同名字段。
            var snap = ServiceSnapshot(status: .ok, email: acct?.email,
                                       plan: acct?.planRaw.map { Fmt.codexPlanName($0) },
                                       subscriptionUntil: acct?.subscriptionUntil ?? CodexAccount.subscriptionUntil(jwt: access),
                                       weekly: previous.weekly, fiveHour: previous.fiveHour,
                                       planRaw: acct?.planRaw, planIsLive: false)
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
                    if let p = u.planRaw, !p.isEmpty {
                        snap.plan = Fmt.codexPlanName(p)
                        snap.planRaw = p
                        snap.planIsLive = true
                    }
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

/// Antigravity 桌面端内置的公开 OAuth 客户端（installed app）。只用于内存里换新令牌。
/// 值不进仓库（GitHub 推送保护会拦），打包时由 scripts/build.sh 从环境变量
/// ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET 写进 Info.plist；缺失时不换新，过期即提示打开 Antigravity。
enum AntigravityOAuth {
    static var clientID: String { (Bundle.main.object(forInfoDictionaryKey: "LLAntigravityClientID") as? String) ?? "" }
    static var clientSecret: String { (Bundle.main.object(forInfoDictionaryKey: "LLAntigravityClientSecret") as? String) ?? "" }
}

final class GeminiLive {
    /// 登录来源与换新都在 GeminiTokenProvider（LanLiangCore）：钥匙串只读，换新结果只写 ~/.lanliang 缓存。
    private let provider = GeminiTokenProvider(
        home: FileManager.default.homeDirectoryForCurrentUser,
        keychain: GeminiLive.readKeychain,
        clientID: AntigravityOAuth.clientID, clientSecret: AntigravityOAuth.clientSecret,
        transport: { req in
            let (d, resp) = try await URLSession.shared.data(for: req)
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        })

    func allowKeychainAgain() { provider.allowKeychainAgain() }

    /// 只读 Antigravity 存的钥匙串项（gemini / antigravity）；栏量从不写钥匙串。
    private static func readKeychain() -> GeminiTokenProvider.KeychainRead {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "gemini",
                                kSecAttrAccount as String: "antigravity",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess: return (out as? Data).map { .found($0) } ?? .notFound
        case errSecItemNotFound: return .notFound
        default: return .denied
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

    /// 用给定令牌查套餐、邮箱和额度，结果写进 snap。
    private func query(token: String, into snap: inout ServiceSnapshot) async throws {
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
        guard let project = assist?.project else { snap.status = .fetchFailed; return }
        let q = try await post("retrieveUserQuotaSummary", token: token,
                               ua: "antigravity/hub/\(v) (aidev_client; os_type=darwin; arch=\(arch))",
                               body: ["project": project])
        if let parsed = GeminiQuota.parse(q) {
            snap.weekly = parsed.weekly
            snap.fiveHour = parsed.fiveHour
        } else {
            snap.status = .fetchFailed
        }
    }

    func fetch(previous: ServiceSnapshot) async -> ServiceSnapshot {
        let cred: GeminiCredential, source: GeminiTokenProvider.Source
        switch provider.load() {
        case let .found(c, s): cred = c; source = s
        case .none: return .init(status: .notLoggedIn)
        case .denied: return .init(status: .keychainDenied)
        }
        var snap = previous
        snap.status = .ok
        if let id = cred.idToken, let email = JWT.payload(id)?["email"] as? String { snap.email = email }
        do {
            do {
                try await query(token: try await provider.accessToken(cred, source: source), into: &snap)
            } catch HTTPFailure.unauthorized {
                // 接口 401：换新令牌后重试一次；换新被拒才算登录过期
                try await query(token: try await provider.accessToken(cred, source: source, force: true), into: &snap)
            }
        } catch HTTPFailure.unauthorized {
            snap.status = .loginExpired
        } catch GeminiTokenProvider.TokenError.expired {
            snap.status = .loginExpired
        } catch {
            snap.status = .fetchFailed
        }
        return snap
    }
}
