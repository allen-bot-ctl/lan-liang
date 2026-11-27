import XCTest
@testable import LanLiangCore

/// 契约 0.3.14：官方凭据经 security 读、15 分钟提前换新、401 只重试一次、invalid_grant、缓存与账号切换。
/// 全部用假的 security 结果和假 HTTP，不需要真实客户端值或令牌。
final class GeminiCredentialFlowTests: XCTestCase {
    var home: URL!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lanliang-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

    func cred(_ at: String, rt: String?, expiry: Date?, email: String? = nil) -> GeminiCredential {
        GeminiCredential(accessToken: at, refreshToken: rt, expiry: expiry, idToken: nil, email: email)
    }
    func blob(_ c: GeminiCredential) -> Data {
        Data((GeminiCredential.keychainPrefix + c.fileData().base64EncodedString()).utf8)
    }
    func perms(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// respond 收到请求里的 refresh_token，返回响应体和状态码。
    func provider(official: Box<GeminiOfficialSource.Read>, calls: Box<[String]>, clientID: String = "cid",
                  now: Box<Date>? = nil, respond: @escaping (String) -> (String, Int)) -> GeminiTokenProvider {
        let clock = now ?? Box(t0)
        return GeminiTokenProvider(
            home: home, official: { official.v }, clientID: clientID, clientSecret: clientID.isEmpty ? "" : "sec",
            transport: { req in
                let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                let rt = URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "refresh_token" }?.value ?? ""
                calls.v.append(rt)
                let (b, c) = respond(rt)
                return (Data(b.utf8), c)
            }, now: { clock.v })
    }

    /// 额度查询替身：记录用到的访问令牌；401 用 TokenError.expired 表示（和 DataSource 一致）。
    func run(_ p: GeminiTokenProvider, used: Box<[String]>, reject: Set<String> = []) async throws -> String {
        try await p.withAccess { c in
            used.v.append(c.accessToken)
            if reject.contains(c.accessToken) { throw GeminiTokenProvider.TokenError.expired }
            return c.accessToken
        }
    }

    // MARK: 解码钥匙串值

    func testDecodesAllStoredValueEncodings() {
        let c = GeminiCredential(accessToken: "a", refreshToken: "r", expiry: t0, idToken: "i", email: "e@x")
        let json = c.fileData()
        let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
        let forms: [Data] = [
            json,
            blob(c),
            Data((GeminiCredential.keychainHexPrefix + hex(json)).utf8),
            Data(hex(blob(c)).utf8),            // security -w 对非文本值打印整段十六进制
            Data(hex(json).uppercased().utf8),
            Data(("  " + String(data: blob(c), encoding: .utf8)! + "\n").utf8),
        ]
        for f in forms { XCTAssertEqual(GeminiCredential.parse(f), c) }
        XCTAssertNil(GeminiCredential.parse(Data("go-keyring-base64:@@@".utf8)))
        XCTAssertNil(GeminiCredential.parse(Data("not json".utf8)))
        XCTAssertNil(GeminiCredential.parse(Data(#"{"token":{}}"#.utf8)))
    }

    func testEmailComesFromIDTokenWhenNotStored() {
        let payload = Data(#"{"email":"boss@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let json = #"{"token":{"access_token":"a","refresh_token":"r"},"id_token":"h.\#(payload).s"}"#
        XCTAssertEqual(GeminiCredential.parse(Data(json.utf8))?.email, "boss@example.com")
    }

    // MARK: security 退出码

    func testSecurityExitCodes() {
        let d = Data("x".utf8)
        XCTAssertEqual(GeminiOfficialSource.interpret(.init(stdout: d, exitCode: 0)), .found(d))
        XCTAssertEqual(GeminiOfficialSource.interpret(.init(stdout: Data(), exitCode: 44)), .notFound)
        XCTAssertEqual(GeminiOfficialSource.interpret(.init(stdout: Data(), exitCode: -1, timedOut: true)), .unavailable)
        XCTAssertEqual(GeminiOfficialSource.interpret(.init(stdout: Data(), exitCode: 51)), .unavailable)
        XCTAssertEqual(GeminiOfficialSource.interpret(nil), .unavailable)
        XCTAssertEqual(GeminiOfficialSource.arguments, ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"])
    }

    func testRunSecurityTimesOutAndReadsStdout() {
        // 用 /bin/sh 代替 security，只测超时与输出、退出码的处理。
        let slow = GeminiOfficialSource.runSecurity(path: "/bin/sh", arguments: ["-c", "sleep 5"], timeout: 0.3)
        XCTAssertEqual(slow?.timedOut, true)
        XCTAssertEqual(GeminiOfficialSource.interpret(slow), .unavailable)
        let ok = GeminiOfficialSource.runSecurity(path: "/bin/sh", arguments: ["-c", "printf abc; echo err >&2; exit 44"])
        XCTAssertEqual(ok?.exitCode, 44)
        XCTAssertEqual(ok?.stdout, Data("abc".utf8))
        XCTAssertNil(GeminiOfficialSource.runSecurity(path: "/nonexistent/security"))
    }

    func testExit0UsesOfficialAndWritesPrivateCache() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 + 3600))))
        let p = provider(official: official, calls: Box([]), respond: { _ in ("", 500) })
        let used = Box<[String]>([])
        let token = try await run(p, used: used)
        XCTAssertEqual(token, "at")
        XCTAssertEqual(perms(GeminiTokenCache.file(home: home)), 0o600)
        XCTAssertEqual(perms(GeminiTokenCache.directory(home: home)), 0o700)
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.refreshToken, "rt")
    }

    func testExit44IsNotLoggedInAndDeletesCache() async throws {
        try GeminiTokenCache.write(cred("old", rt: "rt", expiry: t0 + 3600), home: home)
        let p = provider(official: Box(.notFound), calls: Box([]), respond: { _ in ("", 500) })
        do { _ = try await run(p, used: Box([])); XCTFail("应是未登录") }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .notLoggedIn) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: GeminiTokenCache.file(home: home).path))
    }

    func testTimeoutOrOtherFailureKeepsUsingCache() async throws {
        try GeminiTokenCache.write(cred("cached", rt: "rt", expiry: t0 + 3600), home: home)
        let p = provider(official: Box(.unavailable), calls: Box([]), respond: { _ in ("", 500) })
        let token = try await run(p, used: Box([]))
        XCTAssertEqual(token, "cached")
        XCTAssertNotNil(GeminiTokenCache.read(home: home))
    }

    func testUnavailableWithoutCacheIsUnavailable() async {
        let p = provider(official: Box(.unavailable), calls: Box([]), respond: { _ in ("", 500) })
        do { _ = try await run(p, used: Box([])); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .unavailable) }
    }

    func testFileFallbackWhenKeychainItemMissing() async throws {
        let f = GeminiCredential.candidateFiles(home: home)[1]
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cred("file-at", rt: "file-rt", expiry: t0 + 3600).fileData().write(to: f)
        let p = provider(official: Box(.notFound), calls: Box([]), respond: { _ in ("", 500) })
        let token = try await run(p, used: Box([]))
        XCTAssertEqual(token, "file-at")
        // 只读：官方文件不被改动
        XCTAssertEqual(GeminiCredential.parse(try Data(contentsOf: f))?.accessToken, "file-at")
    }

    // MARK: 换新

    func testRefreshSkewIsFifteenMinutes() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 + 16 * 60))))
        let calls = Box<[String]>([])
        let p = provider(official: official, calls: calls,
                         respond: { _ in (#"{"access_token":"new","expires_in":3600}"#, 200) })
        let got1 = try await run(p, used: Box([]))
        XCTAssertEqual(got1, "at")
        XCTAssertTrue(calls.v.isEmpty)

        try? FileManager.default.removeItem(at: GeminiTokenCache.file(home: home))
        official.v = .found(blob(cred("at", rt: "rt", expiry: t0 + 14 * 60)))
        let got2 = try await run(p, used: Box([]))
        XCTAssertEqual(got2, "new")
        XCTAssertEqual(calls.v, ["rt"])
        let saved = GeminiTokenCache.read(home: home)
        XCTAssertEqual(saved?.accessToken, "new")
        XCTAssertEqual(saved?.expiry, t0 + 3600)       // 按接口返回的写，不截短
    }

    func testRefreshKeepsRotatedRefreshAndIDTokens() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 - 1))))
        let p = provider(official: official, calls: Box([]), respond: { _ in
            (#"{"access_token":"new","expires_in":7200,"refresh_token":"rt2","id_token":"x.e30.y"}"#, 200)
        })
        let got3 = try await run(p, used: Box([]))
        XCTAssertEqual(got3, "new")
        let saved = GeminiTokenCache.read(home: home)
        XCTAssertEqual(saved?.refreshToken, "rt2")
        XCTAssertEqual(saved?.idToken, "x.e30.y")
        XCTAssertEqual(saved?.expiry, t0 + 7200)

        // 没给新 refresh_token 时保留旧的
        try? FileManager.default.removeItem(at: GeminiTokenCache.file(home: home))
        let p2 = provider(official: official, calls: Box([]), respond: { _ in (#"{"access_token":"n2"}"#, 200) })
        _ = try await run(p2, used: Box([]))
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.refreshToken, "rt")
    }

    func testCachedRefreshedTokenIsReusedWhileOfficialIsStale() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("old", rt: "rt", expiry: t0 - 60))))
        let calls = Box<[String]>([])
        let p = provider(official: official, calls: calls,
                         respond: { _ in (#"{"access_token":"new","expires_in":3600}"#, 200) })
        _ = try await run(p, used: Box([]))
        let got4 = try await run(p, used: Box([]))
        XCTAssertEqual(got4, "new")   // 第二个周期用缓存里的新令牌
        XCTAssertEqual(calls.v.count, 1)
    }

    func testUnauthorizedForcesOneRefreshAndOneRetry() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 + 3600))))
        let calls = Box<[String]>([])
        let p = provider(official: official, calls: calls,
                         respond: { _ in (#"{"access_token":"fresh","expires_in":3600}"#, 200) })
        let used = Box<[String]>([])
        let got5 = try await run(p, used: used, reject: ["at"])
        XCTAssertEqual(got5, "fresh")
        XCTAssertEqual(used.v, ["at", "fresh"]); XCTAssertEqual(calls.v.count, 1)

        // 换新后还是 401：只重试一次，然后按登录过期
        let used2 = Box<[String]>([])
        do { _ = try await run(p, used: used2, reject: ["fresh", "fresh2"]); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        XCTAssertEqual(used2.v.count, 2)
        XCTAssertEqual(calls.v.count, 2)
    }

    func testInvalidGrantRereadsOnceThenExpiredAndRecoversWhenRefreshTokenChanges() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "dead", expiry: t0 - 1))))
        let calls = Box<[String]>([])
        let p = provider(official: official, calls: calls, respond: { rt in
            rt == "dead" ? (#"{"error":"invalid_grant"}"#, 400) : (#"{"access_token":"ok","expires_in":3600}"#, 200)
        })
        let reads = p.officialReads
        do { _ = try await run(p, used: Box([])); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        XCTAssertEqual(p.officialReads - reads, 2)          // 周期开头一次 + invalid_grant 后重读一次
        XCTAssertEqual(calls.v, ["dead"])
        // 下个周期 refresh_token 没变：直接登录过期，不再请求令牌接口
        do { _ = try await run(p, used: Box([])); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        XCTAssertEqual(calls.v, ["dead"])
        // 老板在 Antigravity 重新登录：refresh_token 变了，自动恢复
        official.v = .found(blob(cred("at2", rt: "alive", expiry: t0 - 1)))
        let got6 = try await run(p, used: Box([]))
        XCTAssertEqual(got6, "ok")
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.refreshToken, "alive")
    }

    func testInvalidGrantPicksUpNewOfficialLoginInSameCycle() async throws {
        try GeminiTokenCache.write(cred("c", rt: "dead", expiry: t0 - 1), home: home)
        let official = Box<GeminiOfficialSource.Read>(.unavailable)
        // 官方这次没读到，用缓存；换新被拒后重读一次，正好读到新登录
        let p2 = GeminiTokenProvider(home: home, official: { () -> GeminiOfficialSource.Read in
            defer { official.v = .found(self.blob(self.cred("n", rt: "alive", expiry: self.t0 - 1))) }
            return official.v
        }, clientID: "cid", clientSecret: "sec", transport: { req in
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            return body.contains("refresh_token=dead") ? (Data("{}".utf8), 400) : (Data(#"{"access_token":"ok"}"#.utf8), 200)
        }, now: { self.t0 })
        let got7 = try await run(p2, used: Box([]))
        XCTAssertEqual(got7, "ok")
    }

    func testNetworkFailureIsNotLoginExpiry() async throws {
        // 令牌还没过期但进了 15 分钟窗口：换新失败照用旧令牌
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 + 300))))
        let p = provider(official: official, calls: Box([]), respond: { _ in ("", 503) })
        let got8 = try await run(p, used: Box([]))
        XCTAssertEqual(got8, "at")
        // 已经过期：失败（保留旧数据、下周期重试），不是登录过期
        official.v = .found(blob(cred("at", rt: "rt", expiry: t0 - 1)))
        try? FileManager.default.removeItem(at: GeminiTokenCache.file(home: home))
        do { _ = try await run(p, used: Box([])); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .failed) }
    }

    func testWithoutClientValuesRefreshIsDisabled() async throws {
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 + 60))))
        let calls = Box<[String]>([])
        let p = provider(official: official, calls: calls, clientID: "", respond: { _ in ("", 500) })
        XCTAssertFalse(p.canRefresh)
        let got9 = try await run(p, used: Box([]))
        XCTAssertEqual(got9, "at")
        official.v = .found(blob(cred("at", rt: "rt", expiry: t0 - 1)))
        GeminiTokenCache.remove(home: home)
        do { _ = try await run(p, used: Box([])); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        XCTAssertTrue(calls.v.isEmpty)
    }

    // MARK: 缓存与账号切换

    func testRefreshTokenChangeOverwritesCacheAndSwitchesAccount() async throws {
        try GeminiTokenCache.write(cred("a-at", rt: "a-rt", expiry: t0 + 3600, email: "a@x"), home: home)
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("b-at", rt: "b-rt", expiry: t0 + 3600, email: "b@x"))))
        let p = provider(official: official, calls: Box([]), respond: { _ in ("", 500) })
        let email = try await p.withAccess { $0.email }
        XCTAssertEqual(email, "b@x")
        let saved = GeminiTokenCache.read(home: home)
        XCTAssertEqual(saved?.refreshToken, "b-rt"); XCTAssertEqual(saved?.accessToken, "b-at")
    }

    func testLegacyCacheWithoutRefreshTokenIsDroppedAndRebuilt() async throws {
        try GeminiTokenCache.write(cred("legacy", rt: nil, expiry: t0 + 3600), home: home)
        XCTAssertNil(GeminiTokenCache.read(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: GeminiTokenCache.file(home: home).path))
        try GeminiTokenCache.write(cred("legacy", rt: nil, expiry: t0 + 3600), home: home)
        let official = Box<GeminiOfficialSource.Read>(.found(blob(cred("at", rt: "rt", expiry: t0 + 3600))))
        let p = provider(official: official, calls: Box([]), respond: { _ in ("", 500) })
        let got10 = try await run(p, used: Box([]))
        XCTAssertEqual(got10, "at")
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.refreshToken, "rt")
    }

    func testCacheIsPrivateAndAtomic() throws {
        let a = cred("a", rt: "r", expiry: t0, email: "e@x")
        try GeminiTokenCache.write(a, home: home)
        XCTAssertEqual(perms(GeminiTokenCache.file(home: home)), 0o600)
        // 写到一半中断留下的临时文件不影响原文件
        let partial = GeminiTokenCache.directory(home: home).appendingPathComponent(".gemini-token.crash.tmp")
        try Data(#"{"token":{"access_tok"#.utf8).write(to: partial)
        XCTAssertEqual(GeminiTokenCache.read(home: home), a)
        // 再写一次是原子替换：没有残留临时文件以外的东西，内容整份换掉
        let b = cred("b", rt: "r2", expiry: t0)
        try GeminiTokenCache.write(b, home: home)
        XCTAssertEqual(GeminiTokenCache.read(home: home), b)
        let names = try FileManager.default.contentsOfDirectory(atPath: GeminiTokenCache.directory(home: home).path)
        XCTAssertEqual(Set(names), ["gemini-token.json", ".gemini-token.crash.tmp"])
        // 权限放宽就不用
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: GeminiTokenCache.file(home: home).path)
        XCTAssertNil(GeminiTokenCache.read(home: home))
    }

    func testStatusCopy() {
        XCTAssertEqual(ServiceSnapshot(status: .loginExpired).message(for: .gemini), "Gemini 登录已过期，请打开 Antigravity 重新登录")
        XCTAssertEqual(ServiceSnapshot(status: .keychainUnavailable).message(for: .gemini), "暂时无法读取 Gemini 登录，栏量会自动重试")
        XCTAssertEqual(ServiceSnapshot(status: .fetchFailed).message(for: .gemini), "Gemini 额度获取失败，栏量会自动重试")
        XCTAssertEqual(ServiceSnapshot(status: .notLoggedIn).message(for: .gemini), "未检测到 Antigravity 登录")
    }
}

/// 源码红线：Gemini 不再用 SecItem / SecKeychain 读钥匙串；仓库里没有 OAuth 客户端值；不把令牌打进日志。
final class GeminiSourceHygieneTests: XCTestCase {
    func repoFiles() -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var out: [(String, String)] = []
        for dir in ["App", "Sources", "scripts", ".github"] {
            let base = root.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where ["swift", "sh", "yml", "yaml", "py", "plist"].contains(u.pathExtension) {
                if let s = try? String(contentsOf: u, encoding: .utf8) { out.append((u.path, s)) }
            }
        }
        XCTAssertFalse(out.isEmpty)
        return out
    }

    func testNoNativeKeychainAPIs() {
        for (path, s) in repoFiles() where path.hasSuffix(".swift") {
            for banned in ["SecItemCopyMatching", "SecKeychain", "SecItemAdd", "SecItemUpdate", "kSecClassGenericPassword"] {
                XCTAssertFalse(s.contains(banned), "\(path) 不应出现 \(banned)")
            }
        }
    }

    func testNoOAuthClientValuesInSource() {
        for (path, s) in repoFiles() {
            XCTAssertFalse(s.contains(".apps.googleusercontent.com"), "\(path) 不应含 OAuth 客户端 ID")
            XCTAssertFalse(s.contains("GOCSPX-"), "\(path) 不应含 OAuth 客户端密钥")
        }
    }

    func testGeminiCodeNeverLogsTokens() {
        for (path, s) in repoFiles() where path.hasSuffix(".swift") && (path.contains("Gemini") || path.hasSuffix("DataSource.swift")) {
            for line in s.split(separator: "\n") where line.contains("print(") || line.contains("NSLog(") || line.contains("os_log(") {
                for word in ["accessToken", "refreshToken", "idToken", "access_token", "refresh_token", "stdout", "clientSecret"] {
                    XCTAssertFalse(line.contains(word), "\(path) 日志里不应出现 \(word): \(line)")
                }
            }
        }
    }
}
