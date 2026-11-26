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

    func testExplicitRecoveryBypassesCacheThenRetainsAcceptedKeychainOnlyInMemory() async throws {
        try GeminiTokenCache.write(credential("stale-cache"), home: home)
        let next = credential("signed-in")
        let p = provider { .found(next.fileData()) }
        p.allowKeychainAgain()
        let first = try await p.withKeylessAccess { $0.accessToken }
        let second = try await p.withKeylessAccess { $0.accessToken }
        XCTAssertEqual([first, second], ["signed-in", "signed-in"])
        XCTAssertEqual(p.keychainReads, 1)
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.accessToken, "stale-cache")
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

    func testDirectForcedRefreshWithoutClientConfigIsExpired() async throws {
        let p = provider()
        do {
            _ = try await p.accessToken(credential("working"), source: .cache, force: true)
            XCTFail("Expected expiry")
        } catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        XCTAssertEqual(p.keychainReads, 0)
    }
}
