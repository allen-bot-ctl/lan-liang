import Foundation

extension GeminiCredential {
    /// 序列化成和 Antigravity 令牌文件相同的 JSON（0.1.0 契约 §3.1）。
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
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// 栏量自己的 Gemini 登录缓存：~/.lanliang/gemini-token.json（目录 700、文件 600、原子写入）。
public enum GeminiTokenCache {
    public static func directory(home: URL) -> URL { home.appendingPathComponent(".lanliang", isDirectory: true) }
    public static func file(home: URL) -> URL { directory(home: home).appendingPathComponent("gemini-token.json") }

    public static func read(home: URL) -> GeminiCredential? {
        FileManager.default.contents(atPath: file(home: home).path).flatMap(GeminiCredential.parse)
    }

    /// 先写同目录临时文件（600），再 rename 覆盖，读的一方不会看到半个文件。
    public static func write(_ c: GeminiCredential, home: URL) throws {
        let fm = FileManager.default
        let dir = directory(home: home)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".gemini-token.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: c.fileData(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if rename(tmp.path, file(home: home).path) != 0 {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Gemini 登录来源与令牌换新（契约 0.1.3 §2）：
/// 读取顺序 ~/.gemini 两份文件 → ~/.lanliang 缓存 → 钥匙串（只读）。
/// 只有从钥匙串读到时才写缓存；令牌来自缓存时换新结果写回缓存；
/// 缓存里的 refresh_token 被拒时回钥匙串重读一次，本次运行不再反复读。
public final class GeminiTokenProvider {
    public enum KeychainRead: Equatable { case found(Data), notFound, denied }
    public enum Source: Equatable { case antigravityFile, cache }
    public enum Load: Equatable { case found(GeminiCredential, Source), none, denied }
    public enum TokenError: Error, Equatable { case expired, failed, notLoggedIn, keychainDenied }

    private let home: URL
    private let keychain: () -> KeychainRead
    private let noninteractiveKeychain: (() -> KeychainRead)?
    private let clientID: String
    private let clientSecret: String
    private let transport: GeminiTokenRefresh.Transport
    private let now: () -> Date
    private let lock = NSLock()

    private var keychainDenied = false
    private var keychainRetried = false
    private var keylessRereadRequested = false
    private enum KeylessOrigin: Equatable { case file(Int), keychain, cache }
    private var keylessPreferred: KeylessOrigin?
    private var keylessAcceptedKeychain: GeminiCredential?
    public var canRefresh: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    /// 来自 Antigravity 文件时，换新的令牌只放内存（不写 ~/.gemini）。
    private var memory: (refreshToken: String, access: String, expiry: Date)?

    /// 测试/诊断用：本次运行读了几次钥匙串。
    public private(set) var keychainReads = 0

    public init(home: URL, keychain: @escaping () -> KeychainRead,
                noninteractiveKeychain: (() -> KeychainRead)? = nil, clientID: String, clientSecret: String,
                transport: @escaping GeminiTokenRefresh.Transport, now: @escaping () -> Date = Date.init) {
        self.home = home; self.keychain = keychain; self.noninteractiveKeychain = noninteractiveKeychain
        self.clientID = clientID; self.clientSecret = clientSecret
        self.transport = transport; self.now = now
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// 用户点了「重新授权」：允许再读钥匙串。
    public func allowKeychainAgain() {
        locked {
            keychainDenied = false
            keychainRetried = false
            keylessRereadRequested = true
        }
    }

    private func readKeychain() -> KeychainRead {
        if locked({ keychainDenied }) { return .denied }
        locked { keychainReads += 1 }
        let r = keychain()
        if r == .denied { locked { keychainDenied = true } }
        return r
    }

    /// 钥匙串读到就写缓存并返回。
    private func loadFromKeychain() -> Load {
        switch readKeychain() {
        case .found(let d):
            guard let c = GeminiCredential.parse(d) else { return .none }
            try? GeminiTokenCache.write(c, home: home)
            return .found(c, .cache)
        case .notFound: return .none
        case .denied: return .denied
        }
    }

    public func load() -> Load {
        for f in GeminiCredential.candidateFiles(home: home) {
            if let d = FileManager.default.contents(atPath: f.path), let c = GeminiCredential.parse(d) {
                return .found(c, .antigravityFile)
            }
        }
        if let c = GeminiTokenCache.read(home: home) { return .found(c, .cache) }
        return loadFromKeychain()
    }

    /// Tries current credentials with the normal quota request, never the refresh endpoint.
    /// A background refresh cannot prompt for keychain access. An explicit re-read skips
    /// the app cache and in-memory credentials; it checks both provider files before one keychain read.
    public func withKeylessAccess<T>(_ query: (GeminiCredential) async throws -> T) async throws -> T {
        let context = locked { () -> (Bool, KeylessOrigin?, GeminiCredential?, Bool) in
            let result = (keylessRereadRequested, keylessPreferred, keylessAcceptedKeychain, keychainDenied)
            keylessRereadRequested = false
            return result
        }
        let (reread, preferred, keychainCredential, denied) = context
        var sawCredential = keychainCredential != nil
        var attempted = Set<String>()
        var rejected = false

        func files() -> [(KeylessOrigin, GeminiCredential)] {
            GeminiCredential.candidateFiles(home: home).enumerated().compactMap { index, file in
                guard let data = FileManager.default.contents(atPath: file.path),
                      let credential = GeminiCredential.parse(data) else { return nil }
                return (.file(index), credential)
            }
        }

        func tryCandidates(_ candidates: [(KeylessOrigin, GeminiCredential)]) async throws -> T? {
            for (origin, credential) in candidates {
                sawCredential = true
                guard !credential.accessToken.isEmpty, !credential.isExpired(now: now()),
                      attempted.insert(credential.accessToken).inserted else { continue }
                do {
                    let result = try await query(credential)
                    locked {
                        keylessPreferred = origin
                        if origin == .keychain { keylessAcceptedKeychain = credential }
                    }
                    return result
                } catch TokenError.expired {
                    rejected = true
                    // A 401 may coincide with Antigravity rotating its credential.
                    // Never retry the same token in this request.
                }
            }
            return nil
        }

        var current = files()
        if !reread {
            if let keychainCredential { current.append((.keychain, keychainCredential)) }
            if let cached = GeminiTokenCache.read(home: home) { current.append((.cache, cached)) }
            if let preferred, let i = current.firstIndex(where: { $0.0 == preferred }), i > 0 {
                current.insert(current.remove(at: i), at: 0)
            }
        }
        if let result = try await tryCandidates(current) { return result }
        if rejected, let result = try await tryCandidates(files()) { return result }

        if reread {
            switch readKeychain() {
            case .found(let data):
                if let credential = GeminiCredential.parse(data),
                   let result = try await tryCandidates([(.keychain, credential)]) {
                    return result
                }
            case .denied: throw TokenError.keychainDenied
            case .notFound: break
            }
        } else if denied {
            throw TokenError.keychainDenied
        } else if let noninteractiveKeychain {
            // Only one no-UI read, after candidate files/cache have failed. A locked keychain
            // here may simply require interaction; leave that decision to the explicit CTA.
            locked { keychainReads += 1 }
            if case .found(let data) = noninteractiveKeychain(),
               let credential = GeminiCredential.parse(data),
               let result = try await tryCandidates([(.keychain, credential)]) {
                return result
            }
        }
        throw sawCredential ? TokenError.expired : TokenError.notLoggedIn
    }

    private func refresh(_ rt: String) async throws -> (accessToken: String, expiry: Date) {
        try await GeminiTokenRefresh.refresh(refreshToken: rt, clientID: clientID, clientSecret: clientSecret,
                                             now: now(), transport: transport)
    }

    /// 可用的访问令牌。没过期直接用；过期或 force（接口 401）时换新。
    /// 返回值里的 credential 是换新后的（可能已写回缓存）。
    public func accessToken(_ c: GeminiCredential, source: Source, force: Bool = false) async throws -> String {
        if !force, !c.isExpired(now: now()) { return c.accessToken }
        guard canRefresh else { throw TokenError.expired }
        guard let rt = c.refreshToken, !rt.isEmpty else {
            if source == .cache, let alt = try await retryFromKeychain(replacing: c) { return alt }
            throw TokenError.expired
        }
        if source == .antigravityFile, !force, let m = locked({ memory }), m.refreshToken == rt,
           m.expiry.timeIntervalSince(now()) > 60 { return m.access }
        do {
            let r = try await refresh(rt)
            switch source {
            case .antigravityFile:
                locked { memory = (rt, r.accessToken, r.expiry) }
            case .cache:
                var n = c
                n.accessToken = r.accessToken
                n.expiry = r.expiry
                try? GeminiTokenCache.write(n, home: home)
            }
            return r.accessToken
        } catch is GeminiTokenRefresh.Rejected {
            if source == .cache, let alt = try await retryFromKeychain(replacing: c) { return alt }
            throw TokenError.expired
        } catch {
            throw TokenError.failed
        }
    }

    /// 缓存的 refresh_token 被拒：重读一次钥匙串；内容不同就覆盖缓存再试一次。
    private func retryFromKeychain(replacing old: GeminiCredential) async throws -> String? {
        let first = locked { () -> Bool in
            if keychainRetried { return false }
            keychainRetried = true
            return true
        }
        guard first, case .found(let d) = readKeychain(), let c = GeminiCredential.parse(d), c != old else { return nil }
        try? GeminiTokenCache.write(c, home: home)
        if !c.isExpired(now: now()) { return c.accessToken }
        guard let rt = c.refreshToken, !rt.isEmpty else { return nil }
        do {
            let r = try await refresh(rt)
            var n = c
            n.accessToken = r.accessToken
            n.expiry = r.expiry
            try? GeminiTokenCache.write(n, home: home)
            return r.accessToken
        } catch is GeminiTokenRefresh.Rejected {
            return nil
        } catch {
            throw TokenError.failed
        }
    }
}
