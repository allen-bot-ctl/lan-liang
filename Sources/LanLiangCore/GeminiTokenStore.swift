import Foundation

extension GeminiCredential {
    /// 序列化成和 Antigravity 令牌文件相同的 JSON（0.1.0 契约 §3.1），另存账号邮箱。
    public func fileData() -> Data {
        var tok: [String: Any] = ["access_token": accessToken, "token_type": "Bearer"]
        if let r = refreshToken { tok["refresh_token"] = r }
        if let e = expiry {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            tok["expiry"] = f.string(from: e)
        }
        var obj: [String: Any] = ["token": tok]
        if let id = idToken { obj["id_token"] = id }
        if let e = email { obj["email"] = e }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// 栏量自己的 Gemini 登录缓存：~/.lanliang/gemini-token.json（目录 700、文件 600、原子写入）。
public enum GeminiTokenCache {
    public static func directory(home: URL) -> URL { home.appendingPathComponent(".lanliang", isDirectory: true) }
    public static func file(home: URL) -> URL { directory(home: home).appendingPathComponent("gemini-token.json") }

    /// 读缓存。目录不是 700、文件不是 600 或不归当前用户就不用。
    /// 0.3.13 及以前的缓存只有访问令牌、没有 refresh_token：直接删掉，按官方凭据重建。
    public static func read(home: URL) -> GeminiCredential? {
        let fm = FileManager.default
        let dir = directory(home: home)
        let path = file(home: home)
        func isPrivate(_ target: URL, type: FileAttributeType, mode: UInt16) -> Bool {
            guard let attrs = try? fm.attributesOfItem(atPath: target.path) else { return false }
            return attrs[.type] as? FileAttributeType == type &&
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() &&
                ((attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777 == mode
        }
        guard isPrivate(dir, type: .typeDirectory, mode: 0o700),
              isPrivate(path, type: .typeRegular, mode: 0o600),
              let data = fm.contents(atPath: path.path) else { return nil }
        guard let c = GeminiCredential.parse(data), c.refreshToken != nil else {
            remove(home: home)
            return nil
        }
        return c
    }

    public static func remove(home: URL) {
        try? FileManager.default.removeItem(at: file(home: home))
    }

    /// 先写同目录临时文件（600），再 rename 覆盖，读的一方不会看到半个文件。
    public static func write(_ c: GeminiCredential, home: URL) throws {
        let fm = FileManager.default
        let dir = directory(home: home)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: dir.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".gemini-token.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: c.fileData(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: tmp) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if rename(tmp.path, file(home: home).path) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Gemini 登录来源与令牌换新（契约 0.3.14 §1-§3）：
/// 每个周期先读官方凭据（钥匙串项经 /usr/bin/security，读不到再看 ~/.gemini 两份文件），
/// 再和 ~/.lanliang 缓存对照；访问令牌剩不到 15 分钟就用 refresh_token 换新，结果只写缓存。
/// 从不写钥匙串或 ~/.gemini，从不弹窗。
public final class GeminiTokenProvider {
    public enum TokenError: Error, Equatable {
        /// refresh_token 失效或额度接口两次 401：请用户在 Antigravity 重新登录。
        case expired
        /// 网络或换新接口临时失败：保留旧数据，下个周期重试。
        case failed
        /// security 退出码 44 且没有官方文件：Antigravity 没登录。
        case notLoggedIn
        /// 这次读不到官方凭据，也没有缓存。
        case unavailable
    }

    public static let refreshSkew: TimeInterval = 15 * 60

    private let home: URL
    private let official: () -> GeminiOfficialSource.Read
    private let clientID: String
    private let clientSecret: String
    private let transport: GeminiTokenRefresh.Transport
    private let now: () -> Date
    private let lock = NSLock()
    /// 被令牌接口拒绝过的 refresh_token；官方凭据换成别的之前不再拿它请求。
    private var deadRefreshToken: String?

    /// 测试/诊断用：读了几次官方凭据。
    public private(set) var officialReads = 0

    public var canRefresh: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    public init(home: URL, official: @escaping () -> GeminiOfficialSource.Read,
                clientID: String, clientSecret: String,
                transport: @escaping GeminiTokenRefresh.Transport, now: @escaping () -> Date = Date.init) {
        self.home = home; self.official = official
        self.clientID = clientID; self.clientSecret = clientSecret
        self.transport = transport; self.now = now
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private enum Official { case credential(GeminiCredential), notLoggedIn, unavailable }

    private func readFiles() -> GeminiCredential? {
        for f in GeminiCredential.candidateFiles(home: home) {
            if let d = FileManager.default.contents(atPath: f.path), let c = GeminiCredential.parse(d) { return c }
        }
        return nil
    }

    private func readOfficial() -> Official {
        locked { officialReads += 1 }
        switch official() {
        case .found(let data):
            if let c = GeminiCredential.parse(data) { return .credential(c) }
            return readFiles().map(Official.credential) ?? .unavailable
        case .notFound:
            return readFiles().map(Official.credential) ?? .notLoggedIn
        case .unavailable:
            return readFiles().map(Official.credential) ?? .unavailable
        }
    }

    /// 官方凭据和缓存对照：同一个 refresh_token 用缓存（访问令牌可能更新），
    /// 不同就用官方的覆盖缓存（Antigravity 换了账号或重新登录）。
    private func adopt(_ o: GeminiCredential, cache: GeminiCredential?) -> GeminiCredential {
        guard let rt = o.refreshToken else {
            // 官方凭据没有 refresh_token，换新不了；只用它的访问令牌，不进缓存。
            GeminiTokenCache.remove(home: home)
            return o
        }
        if var c = cache, c.refreshToken == rt {
            var changed = false
            if !o.accessToken.isEmpty, (o.expiry ?? .distantPast) > (c.expiry ?? .distantPast) {
                c.accessToken = o.accessToken; c.expiry = o.expiry; changed = true
            }
            if c.idToken == nil, o.idToken != nil { c.idToken = o.idToken; changed = true }
            if c.email == nil, o.email != nil { c.email = o.email; changed = true }
            if changed { try? GeminiTokenCache.write(c, home: home) }
            return c
        }
        try? GeminiTokenCache.write(o, home: home)
        return o
    }

    private func current() throws -> GeminiCredential {
        let cache = GeminiTokenCache.read(home: home)
        switch readOfficial() {
        case .credential(let o):
            return adopt(o, cache: cache)
        case .notLoggedIn:
            GeminiTokenCache.remove(home: home)
            throw TokenError.notLoggedIn
        case .unavailable:
            if let cache { return cache }
            throw TokenError.unavailable
        }
    }

    /// 用可用的访问令牌查一次；查询里抛 `TokenError.expired`（接口 401）时强制换新、只重试一次。
    public func withAccess<T>(_ query: (GeminiCredential) async throws -> T) async throws -> T {
        var reread = false
        var c = try await ensureFresh(try current(), force: false, reread: &reread)
        do {
            return try await query(c)
        } catch TokenError.expired {
            guard canRefresh, c.refreshToken != nil else { throw TokenError.expired }
            c = try await ensureFresh(c, force: true, reread: &reread)
            return try await query(c)
        }
    }

    private func ensureFresh(_ c: GeminiCredential, force: Bool, reread: inout Bool) async throws -> GeminiCredential {
        let t = now()
        if !force, !c.needsRefresh(now: t, skew: Self.refreshSkew) { return c }
        guard canRefresh, let rt = c.refreshToken else {
            if !force, c.isUsable(now: t) { return c }
            throw TokenError.expired
        }
        if locked({ deadRefreshToken }) == rt { throw TokenError.expired }
        do {
            let r = try await GeminiTokenRefresh.refresh(refreshToken: rt, clientID: clientID,
                                                         clientSecret: clientSecret, now: t, transport: transport)
            var n = c
            n.accessToken = r.accessToken
            n.expiry = r.expiry
            if let x = r.refreshToken { n.refreshToken = x }
            if let id = r.idToken {
                n.idToken = id
                if let e = JWT.payload(id)?["email"] as? String, !e.isEmpty { n.email = e }
            }
            try? GeminiTokenCache.write(n, home: home)
            return n
        } catch is GeminiTokenRefresh.Rejected {
            // invalid_grant：重读一次官方凭据，refresh_token 换过了就用新的。
            if !reread {
                reread = true
                if case .credential(let o) = readOfficial(), let ort = o.refreshToken, ort != rt {
                    return try await ensureFresh(adopt(o, cache: nil), force: force, reread: &reread)
                }
            }
            locked { deadRefreshToken = rt }
            throw TokenError.expired
        } catch {
            if !force, c.isUsable(now: t) { return c }
            throw TokenError.failed
        }
    }
}
