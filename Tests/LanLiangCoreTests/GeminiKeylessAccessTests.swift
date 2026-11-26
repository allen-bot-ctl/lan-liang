import XCTest
@testable import LanLiangCore

final class GeminiKeylessAccessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func credential(_ token: String, expiresIn: TimeInterval = 3600) -> GeminiCredential {
        GeminiCredential(accessToken: token, refreshToken: "synthetic-refresh",
                         expiry: now.addingTimeInterval(expiresIn), idToken: nil)
    }

    private func write(_ c: GeminiCredential, index: Int) throws {
        let path = GeminiCredential.candidateFiles(home: home)[index]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try c.fileData().write(to: path)
    }

    private func provider(noninteractive: (() -> GeminiTokenProvider.KeychainRead)? = nil,
                          _ keychain: @escaping () -> GeminiTokenProvider.KeychainRead = { .notFound }) -> GeminiTokenProvider {
        GeminiTokenProvider(home: home, keychain: keychain, noninteractiveKeychain: noninteractive,
                            clientID: "", clientSecret: "",
                            transport: { _ in XCTFail("Must not contact OAuth"); throw CocoaError(.fileNoSuchFile) },
                            now: { self.now })
    }

    func testExpiredFileCannotShadowAnotherCurrentSource() async throws {
        try write(credential("expired", expiresIn: -1), index: 0)
        try write(credential("current"), index: 1)
        let p = provider { XCTFail("Background request must not prompt"); return .denied }
        let accepted = try await p.withKeylessAccess { $0.accessToken }
        XCTAssertEqual(accepted, "current")
        XCTAssertEqual(p.keychainReads, 0)
    }

    func testRejectedFileTriesAlternateAndUsesSuccessfulOriginNextTime() async throws {
        try write(credential("rejected"), index: 0)
        try write(credential("current"), index: 1)
        let p = provider()
        var queried: [String] = []
        func query(_ c: GeminiCredential) throws -> String {
            queried.append(c.accessToken)
            if c.accessToken == "rejected" { throw GeminiTokenProvider.TokenError.expired }
            return c.accessToken
        }
        let first = try await p.withKeylessAccess { try query($0) }
        let second = try await p.withKeylessAccess { try query($0) }
        XCTAssertEqual([first, second], ["current", "current"])
        XCTAssertEqual(queried, ["rejected", "current", "current"])
    }

    func testRecoveryRereadsFileThatRotatedDuringUnauthorizedResponse() async throws {
        try write(credential("rejected"), index: 0)
        let p = provider()
        let accepted = try await p.withKeylessAccess { c in
            if c.accessToken == "rejected" {
                try self.write(self.credential("fresh"), index: 0)
                throw GeminiTokenProvider.TokenError.expired
            }
            return c.accessToken
        }
        XCTAssertEqual(accepted, "fresh")
        XCTAssertEqual(p.keychainReads, 0)
    }

    func testExplicitRecoveryBypassesCacheThenPersistsOnlyVerifiedShortLivedAccess() async throws {
        try GeminiTokenCache.write(credential("stale-cache"), home: home)
        let next = credential("signed-in")
        let p = provider { .found(next.fileData()) }
        p.allowKeychainAgain()
        let first = try await p.withKeylessAccess { $0.accessToken }
        let second = try await p.withKeylessAccess { $0.accessToken }
        XCTAssertEqual([first, second], ["signed-in", "signed-in"])
        XCTAssertEqual(p.keychainReads, 1)
        let cached = try XCTUnwrap(GeminiTokenCache.readPrivateAccess(home: home))
        XCTAssertEqual(cached.accessToken, "signed-in")
        XCTAssertNil(cached.refreshToken)
        XCTAssertNil(cached.idToken)
    }

    func testExpiryAndDenialRemainDistinctAndQuotaErrorsPropagate() async throws {
        try write(credential("expired", expiresIn: -1), index: 0)
        let p = provider { .denied }
        do {
            _ = try await p.withKeylessAccess { _ -> String in XCTFail("Expired token used"); return "" }
            XCTFail("Expected expiry")
        } catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        p.allowKeychainAgain()
        do {
            _ = try await p.withKeylessAccess { $0.accessToken }
            XCTFail("Expected denial")
        } catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .keychainDenied) }
        try write(credential("current"), index: 0)
        do {
            _ = try await p.withKeylessAccess { _ -> String in throw URLError(.notConnectedToInternet) }
            XCTFail("Expected quota transport failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(p.keychainReads, 1)
    }

    func testSilentKeychainFallbackAfterCachedTokenIsRejected() async throws {
        try GeminiTokenCache.write(credential("cached"), home: home)
        let fresh = credential("current-keychain")
        let p = provider(noninteractive: { .found(fresh.fileData()) }) {
            XCTFail("Automatic recovery cannot request interactive access")
            return .denied
        }
        var queried: [String] = []
        func query(_ c: GeminiCredential) throws -> String {
            queried.append(c.accessToken)
            if c.accessToken == "cached" && queried.count > 1 {
                throw GeminiTokenProvider.TokenError.expired
            }
            return c.accessToken
        }
        let first = try await p.withKeylessAccess { try query($0) }
        let second = try await p.withKeylessAccess { try query($0) }
        let third = try await p.withKeylessAccess { try query($0) }
        XCTAssertEqual([first, second, third], ["cached", "current-keychain", "current-keychain"])
        XCTAssertEqual(queried, ["cached", "cached", "current-keychain", "current-keychain"])
        XCTAssertEqual(p.keychainReads, 1)
    }

    func testRelaunchWithValidCacheUsesZeroKeychainCalls() async throws {
        var upstream = credential("known-current", expiresIn: 24 * 3600)
        upstream.idToken = "synthetic-id"
        let freshData = upstream.fileData()
        let first = provider(noninteractive: { .found(freshData) })
        let firstToken = try await first.withKeylessAccess { $0.accessToken }
        XCTAssertEqual(firstToken, "known-current")
        XCTAssertEqual(first.keychainReads, 1)
        let cached = try XCTUnwrap(GeminiTokenCache.readPrivateAccess(home: home))
        XCTAssertEqual(cached.expiry, now.addingTimeInterval(3600))
        XCTAssertNil(cached.refreshToken)
        XCTAssertNil(cached.idToken)

        try write(credential("source-file-should-not-be-used"), index: 0)
        let restarted = provider(noninteractive: {
            XCTFail("Relaunch with valid cache must not touch Keychain")
            return .denied
        }) {
            XCTFail("Never ask for interactive access during relaunch")
            return .denied
        }
        let cachedToken = try await restarted.withKeylessAccess { $0.accessToken }
        XCTAssertEqual(cachedToken, "known-current")
        XCTAssertEqual(restarted.keychainReads, 0)
    }

    func testExpiredCacheAllowsOnlySilentFallbackUntilUserActs() async throws {
        try GeminiTokenCache.write(credential("past", expiresIn: -1), home: home)
        var interactive = 0
        let p = provider(noninteractive: { .denied }) {
            interactive += 1
            return .found(self.credential("current-after-permission").fileData())
        }
        do {
            _ = try await p.withKeylessAccess { $0.accessToken }
            XCTFail("Expected explicit keychain authorization state")
        } catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .keychainDenied) }
        XCTAssertEqual(interactive, 0)
        XCTAssertEqual(p.keychainReads, 1)
        p.allowKeychainAgain()
        let recovered = try await p.withKeylessAccess { $0.accessToken }
        XCTAssertEqual(recovered, "current-after-permission")
        XCTAssertEqual(interactive, 1)
    }

    func testNetworkFailureLeavesCacheAndNeverOpensKeychain() async throws {
        try GeminiTokenCache.write(credential("valid"), home: home)
        let p = provider(noninteractive: {
            XCTFail("Transport failure must not touch Keychain")
            return .notFound
        })
        do {
            _ = try await p.withKeylessAccess { _ -> String in throw URLError(.notConnectedToInternet) }
            XCTFail("Expected quota network error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(GeminiTokenCache.readPrivateAccess(home: home)?.accessToken, "valid")
        XCTAssertEqual(p.keychainReads, 0)
    }

    func testCacheWithoutExpiryAndUnsafePermissionsAreNotTrusted() async throws {
        var unknown = credential("unknown-expiry")
        unknown.expiry = nil
        try GeminiTokenCache.write(unknown, home: home)
        let p = provider(noninteractive: { .found(self.credential("fresh").fileData()) })
        let selected = try await p.withKeylessAccess { $0.accessToken }
        XCTAssertEqual(selected, "fresh")
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
            ofItemAtPath: GeminiTokenCache.file(home: home).path)
        XCTAssertNil(GeminiTokenCache.readPrivateAccess(home: home))
    }

    func testCacheAcrossSeparateProcessesWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LL_SYNTHETIC_CACHE_HOME"],
              let step = env["LL_SYNTHETIC_CACHE_STEP"], ["seed", "verify"].contains(step) else {
            throw XCTSkip("Run in two separate test processes with an isolated synthetic fixture home.")
        }
        let fixtureHome = URL(fileURLWithPath: path)
        let fresh = credential("synthetic-cross-process")
        let p = GeminiTokenProvider(home: fixtureHome, keychain: {
            XCTFail("Never request interactive Keychain in this test")
            return .denied
        }, noninteractiveKeychain: {
            if step == "seed" { return .found(fresh.fileData()) }
            XCTFail("A new process with valid cache must not touch Keychain")
            return .denied
        }, clientID: "", clientSecret: "", transport: { _ in
            XCTFail("No real OAuth requests in this test")
            throw CocoaError(.fileNoSuchFile)
        }, now: { self.now })
        let result = try await p.withKeylessAccess { $0.accessToken }
        XCTAssertEqual(result, "synthetic-cross-process")
        XCTAssertEqual(p.keychainReads, step == "seed" ? 1 : 0)
    }

    func testDirectForcedRefreshWithoutClientConfigIsExpired() async throws {
        let p = provider()
        do {
            _ = try await p.accessToken(credential("working"), source: .cache, force: true)
            XCTFail("Expected expiry")
        } catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        XCTAssertEqual(p.keychainReads, 0)
    }
}
