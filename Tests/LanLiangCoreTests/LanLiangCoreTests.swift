import XCTest
@testable import LanLiangCore

final class LanLiangCoreTests: XCTestCase {
    func testWindowKindBySeconds() {
        XCTAssertEqual(WindowKind.from(windowSeconds: 18_000), .fiveHour)
        XCTAssertEqual(WindowKind.from(windowSeconds: 604_800), .weekly)
        XCTAssertEqual(WindowKind.from(windowSeconds: 3_600), .other)
    }

    func testMenuBarGroups() {
        let w = QuotaWindow(kind: .weekly, remainingPercent: 77.4, resetsAt: nil)
        let f = QuotaWindow(kind: .fiveHour, remainingPercent: 64, resetsAt: nil)
        XCTAssertEqual(MenuBarText.group(for: .codex, snapshot: ServiceSnapshot(status: .ok, weekly: w)),
                       MenuBarGroup(service: .codex, primary: "77%", secondary: nil))
        XCTAssertEqual(MenuBarText.group(for: .gemini, snapshot: ServiceSnapshot(status: .ok, weekly: w, fiveHour: f))?.secondary, "64%")
        XCTAssertNil(MenuBarText.group(for: .codex, snapshot: ServiceSnapshot(status: .notLoggedIn)))
        XCTAssertNil(MenuBarText.group(for: .codex, snapshot: ServiceSnapshot(status: .apiKeyOnly)))
        XCTAssertNil(MenuBarText.group(for: .gemini, snapshot: ServiceSnapshot(status: .keychainDenied)))
        // 失败时保留上次成功值；从没成功过显示 --
        XCTAssertEqual(MenuBarText.group(for: .codex, snapshot: ServiceSnapshot(status: .fetchFailed, weekly: w))?.primary, "77%")
        XCTAssertEqual(MenuBarText.group(for: .codex, snapshot: ServiceSnapshot(status: .fetchFailed))?.primary, "--")
        XCTAssertEqual(MenuBarText.group(for: .codex, snapshot: ServiceSnapshot(status: .loading))?.primary, "…")
        XCTAssertEqual(MenuBarText.group(for: .gemini, snapshot: ServiceSnapshot(status: .loginExpired, weekly: w))?.primary, "--")
    }

    func testMessages() {
        XCTAssertEqual(ServiceSnapshot(status: .loginExpired).message(for: .codex), "Codex 登录已过期，在终端运行一次 codex 重新登录")
        XCTAssertEqual(ServiceSnapshot(status: .notLoggedIn).message(for: .gemini), "未检测到登录")
        XCTAssertNil(ServiceSnapshot(status: .ok).message(for: .codex))
    }

    func testRemainingClamped() {
        XCTAssertEqual(QuotaWindow(kind: .weekly, remainingPercent: 130, resetsAt: nil).remainingPercent, 100)
        XCTAssertEqual(QuotaWindow(kind: .weekly, remainingPercent: -3, resetsAt: nil).remainingPercent, 0)
    }

    func testMaskEmail() {
        XCTAssertEqual(Fmt.maskEmail("allen@gmail.com"), "a***@gmail.com")
        XCTAssertEqual(Fmt.maskEmail("bad"), "***")
    }

    func testPlanNames() {
        XCTAssertEqual(Fmt.codexPlanName("pro"), "Pro 200")
        XCTAssertEqual(Fmt.codexPlanName("prolite"), "Pro 100")
        XCTAssertEqual(Fmt.codexPlanName("plus"), "Plus")
        XCTAssertEqual(Fmt.codexPlanName("chatgpt_team_x"), "Team")
        XCTAssertEqual(Fmt.codexPlanName("weird"), "weird")
        XCTAssertEqual(Fmt.codexPlanName(nil), "未知")
    }

    func testTokenFormat() {
        XCTAssertEqual(Fmt.tokens(9_999), "9999")
        XCTAssertEqual(Fmt.tokens(12_345), "1.23万")
        XCTAssertEqual(Fmt.tokens(304_000_000), "3.04亿")
    }

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Fmt.countdown(from: now, to: now.addingTimeInterval(17 * 86_400 + 12 * 3_600)), "17天12小时")
        XCTAssertEqual(Fmt.countdown(from: now, to: now.addingTimeInterval(3_660)), "1小时1分")
        XCTAssertEqual(Fmt.countdown(from: now, to: now.addingTimeInterval(-5)), "0分")
    }

    func testDay() {
        let d = Date(timeIntervalSince1970: 1_797_033_600) // 2026-12-12T00:00:00Z
        XCTAssertEqual(Fmt.day(d, timeZone: TimeZone(identifier: "UTC")!), "2026/12/12")
    }

    func testJWTPayload() {
        // header.payload.sig，payload = {"email":"a@b.c"}
        let p = Data(#"{"email":"a@b.c"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(JWT.payload("x.\(p).y")?["email"] as? String, "a@b.c")
        XCTAssertNil(JWT.payload("nope"))
    }
}

final class ParserTests: XCTestCase {
    func data(_ s: String) -> Data { Data(s.utf8) }

    func testCodexWindowsByLength() {
        // 周放在 secondary、5 小时放在 primary 也要认对
        let u = CodexUsage.parse(data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":36,"reset_at":1764655200,"limit_window_seconds":18000},"secondary_window":{"used_percent":"22.6","reset_at":1764999999,"limit_window_seconds":604800}}}"#))!
        XCTAssertEqual(u.fiveHour?.remainingPercent, 64)
        XCTAssertEqual(u.weekly?.remainingPercent, 77)
        XCTAssertEqual(u.weekly?.resetsAt, Date(timeIntervalSince1970: 1764999999))
        let w = CodexUsage.parse(data(#"{"rate_limit":{"primary_window":{"used_percent":23,"reset_at":1,"limit_window_seconds":604800},"secondary_window":null}}"#))!
        XCTAssertEqual(w.weekly?.remainingPercent, 77)
        XCTAssertNil(w.fiveHour)
    }

    func testCodexCredential() {
        XCTAssertEqual(CodexCredential.parse(data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#)), .apiKey)
        XCTAssertEqual(CodexCredential.parse(data(#"{"tokens":{"access_token":"a","id_token":"i","account_id":"c"}}"#)),
                       .oauth(accessToken: "a", idToken: "i", accountID: "c"))
        XCTAssertEqual(CodexCredential.parse(data("{}")), CodexCredential.none)
    }

    func testCodexAccountClaims() {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let iso = "x." + b64(#"{"email":"allen@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro","chatgpt_subscription_active_until":"2026-12-12T08:00:00+00:00"}}"#) + ".y"
        let a = CodexAccount.from(idToken: iso)!
        XCTAssertEqual(a.email, "allen@example.com")
        XCTAssertEqual(a.planRaw, "pro")
        XCTAssertEqual(a.subscriptionUntil, Date(timeIntervalSince1970: 1_797_062_400))
        let num = "x." + b64(#"{"https://api.openai.com/auth":{"chatgpt_subscription_active_until":1797062400}}"#) + ".y"
        XCTAssertEqual(CodexAccount.from(idToken: num)?.subscriptionUntil, Date(timeIntervalSince1970: 1_797_062_400))
    }

    func testProfileDaily() {
        let d = CodexProfile.parseDaily(data(#"{"stats":{"daily_usage_buckets":[{"start_date":"2026-11-23","tokens":304000000},{"start_date":"2026-11-24","tokens":52000000}]}}"#))!
        XCTAssertEqual(d["2026-11-23"], 304_000_000)
        XCTAssertNil(CodexProfile.parseDaily(data(#"{"stats":{}}"#)))
    }

    func testSessionLogOnlyLastUsage() {
        let text = """
        {"timestamp":"2026-11-24T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5200,"output_tokens":310,"total_tokens":5510},"total_token_usage":{"total_tokens":999999}}}}
        {"timestamp":"2026-11-24T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"timestamp":"2026-11-24T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}
        not json token_count
        {"timestamp":"2026-11-24T04:00:00Z","type":"response_item","payload":{"type":"message"}}
        """
        var daily: [String: Int64] = [:]
        CodexSessionLog.accumulate(text, into: &daily, calendar: TokenSeries.calendar(timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(daily, ["2026-11-24": 5630])
    }

    func testGeminiCredentialKeychainPrefix() {
        let json = #"{"token":{"access_token":"ya29","refresh_token":"r","expiry":"2026-11-24T20:30:00Z"},"id_token":"e"}"#
        let kc = GeminiCredential.keychainPrefix + Data(json.utf8).base64EncodedString()
        let a = GeminiCredential.parse(data(json))!, b = GeminiCredential.parse(data(kc))!
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.accessToken, "ya29")
        XCTAssertTrue(a.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testGeminiAssist() {
        let a = GeminiAssist.parse(data(#"{"cloudaicompanionProject":"p1","currentTier":{"id":"free-tier","name":"Free"},"paidTier":{"id":"g1-pro-tier"}}"#))!
        XCTAssertEqual(a.planName, "Pro")
        XCTAssertEqual(a.project, "p1")
        let b = GeminiAssist.parse(data(#"{"cloudaicompanionProject":{"id":"p2"},"currentTier":{"id":"standard-tier"}}"#))!
        XCTAssertEqual(b.planName, "Standard")
        XCTAssertEqual(b.project, "p2")
        XCTAssertNil(GeminiAssist.parse(data("{}"))!.project)
    }

    func testGeminiQuotaMissingFractionIsZero() {
        let q = GeminiQuota.parse(data(#"{"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":0.44},{"bucketId":"gemini-5h","resetTime":"2026-11-24T22:54:47Z"}]},{"buckets":[{"bucketId":"3p-weekly","remainingFraction":1}]}]}"#))!
        XCTAssertEqual(q.weekly?.remainingPercent, 44)
        XCTAssertEqual(q.fiveHour?.remainingPercent, 0)
        XCTAssertNotNil(q.fiveHour?.resetsAt)
    }

    func testPlanTableRows() {
        let rows: [(String, String)] = [("free", "Free"), ("plus", "Plus"), ("prolite", "Pro 100"), ("pro-lite", "Pro 100"),
            ("pro", "Pro 200"), ("promax", "Pro 500"), ("pro-max", "Pro 500"), ("team", "Team"),
            ("chatgpt_business", "Business"), ("enterprise", "Enterprise"), ("k12_edu", "Edu"), ("other", "other")]
        for (raw, name) in rows { XCTAssertEqual(Fmt.codexPlanName(raw), name, raw) }
    }

    func testTokenBars() {
        let cal = TokenSeries.calendar(timeZone: TimeZone(identifier: "UTC")!)
        let now = Date(timeIntervalSince1970: 1_795_478_400 + 3_600) // 2026-11-24 01:00 UTC（周二）
        let official: [String: Int64] = ["2026-11-23": 304_000_000, "2026-11-24": 5]
        let local: [String: Int64] = ["2026-11-24": 7, "2026-11-01": 9]
        let d = TokenSeries.bars(range: .daily, official: official, local: local, now: now, calendar: cal)
        XCTAssertEqual(d.count, 30)
        XCTAssertEqual(d.last?.key, "2026-11-24")
        XCTAssertEqual(d.last?.value, 5)
        XCTAssertEqual(d[28].label, "11月23日")
        let w = TokenSeries.bars(range: .weekly, official: official, local: local, now: now, calendar: cal)
        XCTAssertEqual(w.count, 12)
        XCTAssertEqual(w.last?.key, "2026-11-23")
        XCTAssertEqual(w.last?.label, "11月23日–11月29日")
        XCTAssertEqual(w.last?.official, 304_000_005)
        let m = TokenSeries.bars(range: .monthly, official: nil, local: local, now: now, calendar: cal)
        XCTAssertEqual(m.count, 6)
        XCTAssertEqual(m.last?.label, "2026年11月")
        XCTAssertEqual(m.last?.value, 16)
        XCTAssertFalse(m.last!.usesOfficial)
    }
}

final class FakeDataTests: XCTestCase {
    func testDecode() throws {
        let json = #"{"now":"2026-11-24T19:00:00Z","codex":{"status":"ok","email":"allen@example.com","plan":"Pro 200","subscriptionUntil":"2026-12-12T08:00:00Z","weekly":{"kind":"weekly","remainingPercent":77,"resetsAt":1797000000}},"gemini":{"status":"notLoggedIn"},"official":{"2026-11-23":304000000},"local":{}}"#
        let f = try FakeData.decode(Data(json.utf8))
        XCTAssertEqual(f.codex.weekly?.remainingPercent, 77)
        XCTAssertEqual(f.gemini.status, .notLoggedIn)
        XCTAssertEqual(f.official?["2026-11-23"], 304_000_000)
        XCTAssertEqual(f.codex.subscriptionUntil, Date(timeIntervalSince1970: 1_797_062_400))
    }
}

final class GeminiRefreshTests: XCTestCase {
    func testRefreshSuccessUsesFormAndParsesExpiry() async throws {
        var seen: URLRequest?
        let now = Date(timeIntervalSince1970: 1_000)
        let r = try await GeminiTokenRefresh.refresh(refreshToken: "1//r+t", clientID: "cid", clientSecret: "sec", now: now) { req in
            seen = req
            return (Data(#"{"access_token":"new-at","expires_in":3599,"token_type":"Bearer"}"#.utf8), 200)
        }
        XCTAssertEqual(r.accessToken, "new-at")
        XCTAssertEqual(r.expiry, now.addingTimeInterval(3599))
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.absoluteString, "https://oauth2.googleapis.com/token")
        let body = String(data: seen?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=1//r%2Bt") || body.contains("refresh_token=1%2F%2Fr%2Bt"))
        XCTAssertTrue(body.contains("client_id=cid"))
    }

    func testRefreshFailures() async {
        let now = Date()
        for (body, code) in [(#"{"error":"invalid_grant"}"#, 400), (#"{"token_type":"Bearer"}"#, 200), ("oops", 500)] {
            do {
                _ = try await GeminiTokenRefresh.refresh(refreshToken: "r", clientID: "c", clientSecret: "s", now: now) { _ in
                    (Data(body.utf8), code)
                }
                XCTFail("应失败: \(code)")
            } catch {
                XCTAssertEqual(error as? GeminiTokenRefresh.Failed, GeminiTokenRefresh.Failed())
            }
        }
        // 没有 client secret 或 refresh_token 时不发请求
        var called = false
        do {
            _ = try await GeminiTokenRefresh.refresh(refreshToken: "", clientID: "c", clientSecret: "s", now: now) { _ in
                called = true; return (Data(), 200)
            }
            XCTFail("应失败")
        } catch {}
        XCTAssertFalse(called)
    }

    func testParseDefaultExpiry() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(GeminiTokenRefresh.parse(Data(#"{"access_token":"a"}"#.utf8), now: now)?.expiry, Date(timeIntervalSince1970: 3_600))
        XCTAssertNil(GeminiTokenRefresh.parse(Data("{}".utf8), now: now))
    }
}
