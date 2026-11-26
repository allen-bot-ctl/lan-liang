import Foundation
import Security
import LocalAuthentication

/// 一次刷新的回调：各自到了就各自调用，都在主线程（契约 0.1.5 §5）。
struct RefreshHandlers {
    /// Codex 额度（wham/usage 一回来就调用，不等用量图）。
    var onCodex: (ServiceSnapshot) -> Void
    /// Codex 官方每日用量；nil = 拉取失败。
    var onCodexOfficial: ([String: Int64]?) -> Void
    var onGemini: (ServiceSnapshot) -> Void
    /// 两家额度都回来后调用一次。
    var onAllDone: () -> Void
}

/// 数据来源：真实（读本机登录 + 调接口）或模拟（LANLIANG_FAKE / --debug-fake）。
protocol DataSource: AnyObject {
    /// 模拟数据里固定的「现在」；真实数据为 nil。
    var fixedNow: Date? { get }
    /// selection：关掉的服务不请求、不回调（契约 0.3.0 §1）。
    func refresh(current: (ServiceSnapshot, ServiceSnapshot), selection: ServiceSelection, handlers: RefreshHandlers)
    func allowKeychainAgain()
    /// Gemini 本机 Token 历史：后台串行扫描，结果回主线程；扫描还在跑时不再新起。
    func refreshGeminiHistory(completion: @escaping (GeminiHistory) -> Void)
    func loadCodexModels(now: Date, completion: @escaping (DailyModelWeights?) -> Void)
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

    private func load() -> FakeData? {
        guard let d = FileManager.default.contents(atPath: path), let f = try? FakeData.decode(d) else {
            print("DEBUG_FAKE error path=\(path)")
            return nil
        }
        return f
    }

    var fixedNow: Date? { load()?.now }

    func refresh(current: (ServiceSnapshot, ServiceSnapshot), selection: ServiceSelection, handlers h: RefreshHandlers) {
        let f = load()
        DispatchQueue.main.async {
            if selection.codex { h.onCodex(f?.codex ?? .init(status: .fetchFailed)) }
            if selection.gemini { h.onGemini(f?.gemini ?? .init(status: .fetchFailed)) }
            if selection.codex { h.onCodexOfficial(f?.official) }
            h.onAllDone()
        }
    }

    func allowKeychainAgain() {}

    func refreshGeminiHistory(completion: @escaping (GeminiHistory) -> Void) {
        guard let d = FileManager.default.contents(atPath: path), let f = try? FakeData.decode(d),
              let h = f.geminiHistory else { return }
        DispatchQueue.main.async { completion(h) }
    }
    func loadCodexModels(now: Date, completion: @escaping (DailyModelWeights?) -> Void) {
        let data = load()?.codexModelActivity
        DispatchQueue.main.async { completion(data) }
    }

}

// MARK: - 真实数据（只读 ~/.codex、~/.gemini、钥匙串；只写自己的 ~/.lanliang）

enum HTTPFailure: Error { case unauthorized, failed }

private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

private func send(_ req: URLRequest, forbiddenMeansUnauthorized: Bool = true) async throws -> Data {
    var r = req
    r.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || (code == 403 && forbiddenMeansUnauthorized) { throw HTTPFailure.unauthorized }
    guard (200..<300).contains(code) else { throw HTTPFailure.failed }
    return data
}

final class LiveSource: DataSource {
    private let codex = CodexLive()
    private let gemini = GeminiLive()

    var fixedNow: Date? { nil }

    /// 两家额度各自请求、各自显示；Codex 官方用量在额度之后再拉，不拖慢额度。
    func refresh(current: (ServiceSnapshot, ServiceSnapshot), selection: ServiceSelection, handlers h: RefreshHandlers) {
        let codex = self.codex, gemini = self.gemini
        RefreshCoordinator.run(
            codex: { await codex.fetch(previous: current.0, onQuota: { s in DispatchQueue.main.async { h.onCodex(s) } }) },
            gemini: { await gemini.fetch(previous: current.1) },
            selection: selection,
            onCodex: { official in h.onCodexOfficial(official) },
            onGemini: { s in h.onGemini(s) },
            onAllDone: { h.onAllDone() })
    }

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

    private let modelActivityQueue = DispatchQueue(label: "lanliang.codex-model-activity", qos: .utility)
    private var modelActivityBusy = false

    func loadCodexModels(now: Date, completion: @escaping (DailyModelWeights?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !modelActivityBusy else { return }
        modelActivityBusy = true
        modelActivityQueue.async { [weak self] in
            let cal = TokenSeries.calendar()
            let since = cal.date(byAdding: .month, value: -5, to: cal.dateInterval(of: .month, for: now)!.start)!
            let db = CodexCredential.home().appendingPathComponent("state_5.sqlite")
            let activity = CodexModelActivity.read(db: db, since: since, now: now, calendar: cal)
            DispatchQueue.main.async { [weak self] in
                self?.modelActivityBusy = false
                completion(activity)
            }
        }
    }

}

// MARK: Codex

final class CodexLive {
    /// 额度模块只读 auth.json 取登录；模型分布是独立的只读统计。
    /// 额度一回来就通过 onQuota 交出去；返回值是之后拉到的官方每日用量（nil = 失败或没登录）。
    func fetch(previous: ServiceSnapshot, onQuota: (ServiceSnapshot) -> Void) async -> [String: Int64]? {
        guard let data = FileManager.default.contents(atPath: CodexCredential.authFile().path) else {
            onQuota(.init(status: .notLoggedIn)); return nil
        }
        switch CodexCredential.parse(data) {
        case .none:
            onQuota(.init(status: .notLoggedIn)); return nil
        case .apiKey:
            onQuota(.init(status: .apiKeyOnly)); return nil
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
            onQuota(snap)
            guard snap.status != .loginExpired, let d = try? await send(request("wham/profiles/me")) else { return nil }
            return CodexProfile.parseDaily(d)
        }
    }
}

// MARK: Gemini（Antigravity 登录）

final class GeminiLive {
    // 栏量不携带 OAuth 客户端凭据；只读 Antigravity 当前登录状态。
    private let provider = GeminiTokenProvider(
        home: FileManager.default.homeDirectoryForCurrentUser,
        keychain: { GeminiLive.readKeychain(interactive: true) },
        noninteractiveKeychain: { GeminiLive.readKeychain(interactive: false) },
        clientID: "", clientSecret: "",
        transport: { _ in throw GeminiTokenProvider.TokenError.expired })

    func allowKeychainAgain() { provider.allowKeychainAgain() }

    /// 只读 Antigravity 存的钥匙串项（gemini / antigravity）；栏量从不写钥匙串。
    private static func readKeychain(interactive: Bool) -> GeminiTokenProvider.KeychainRead {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "gemini",
                                kSecAttrAccount as String: "antigravity",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        var out: CFTypeRef?
        let status = KeychainInteraction.perform(interactive: interactive) {
            SecItemCopyMatching(q as CFDictionary, &out)
        }
        switch status {
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
        return try await send(r, forbiddenMeansUnauthorized: false)
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
        guard let project = assist?.project else { throw HTTPFailure.failed }
        let q = try await post("retrieveUserQuotaSummary", token: token,
                               ua: "antigravity/hub/\(v) (aidev_client; os_type=darwin; arch=\(arch))",
                               body: ["project": project])
        if let parsed = GeminiQuota.parse(q) {
            snap.weekly = parsed.weekly
            snap.fiveHour = parsed.fiveHour
        } else {
            throw HTTPFailure.failed
        }
    }

    func fetch(previous: ServiceSnapshot) async -> ServiceSnapshot {
        do {
            return try await provider.withKeylessAccess { credential in
                // A successful source may correspond to a different Antigravity account.
                var snap = ServiceSnapshot(status: .ok)
                if let id = credential.idToken { snap.email = JWT.payload(id)?["email"] as? String }
                do {
                    try await query(token: credential.accessToken, into: &snap)
                } catch HTTPFailure.unauthorized {
                    throw GeminiTokenProvider.TokenError.expired
                }
                return snap
            }
        } catch GeminiTokenProvider.TokenError.notLoggedIn {
            var snap = previous
            snap.status = (previous.status == .loginExpired || previous.hasQuota) ? .loginExpired : .notLoggedIn
            return snap
        } catch GeminiTokenProvider.TokenError.keychainDenied {
            var snap = previous
            snap.status = .keychainDenied
            return snap
        } catch GeminiTokenProvider.TokenError.expired {
            var snap = previous
            snap.status = .loginExpired
            return snap
        } catch {
            var snap = previous
            snap.status = .fetchFailed
            return snap
        }
    }
}
