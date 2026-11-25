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
        XCTAssertEqual(MenuBarText.group(for: .gemini, snapshot: ServiceSnapshot(status: .ok, weekly: w, fiveHour: f))?.secondary, "64")
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

    func testQuotaLevel() {
        XCTAssertEqual(QuotaLevel.of(remainingPercent: 100), .normal)
        XCTAssertEqual(QuotaLevel.of(remainingPercent: 20), .normal)
        XCTAssertEqual(QuotaLevel.of(remainingPercent: 19), .critical)
        XCTAssertEqual(QuotaLevel.of(remainingPercent: 0), .critical)
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
                if code == 400 { XCTAssertEqual(error as? GeminiTokenRefresh.Rejected, GeminiTokenRefresh.Rejected()) }
                else { XCTAssertEqual(error as? GeminiTokenRefresh.Failed, GeminiTokenRefresh.Failed()) }
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

final class V012Tests: XCTestCase {
    func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: 0.1.2 订阅有效期

    private func utc(_ s: String) -> Date { parseFlexibleDate(s)! }

    func testSubscriptionTier() {
        for p in ["plus", "prolite", "pro-lite", "pro", "PRO", "promax", "pro-max", "team", "chatgpt_business", "enterprise", "edu"] {
            XCTAssertEqual(CodexSubscription.tier(p), .paid, p)
        }
        XCTAssertEqual(CodexSubscription.tier("free"), .free)
        XCTAssertEqual(CodexSubscription.tier(nil), .unknown)
        XCTAssertEqual(CodexSubscription.tier(""), .unknown)
        XCTAssertEqual(CodexSubscription.tier("guest"), .unknown)
    }

    func testPaidPastDateRollsToCurrentPeriod() {
        // 老板的 Pro 200：id_token 日期 10/12 已过去，推到 12/12。
        let now = utc("2026-11-24T19:00:00Z")
        let line = CodexSubscription.line(raw: utc("2026-10-12T08:00:00Z"), planRaw: "pro", planIsLive: true, now: now)
        XCTAssertEqual(line, .active(until: utc("2026-12-12T08:00:00Z"), daysLeft: 17))
        XCTAssertEqual(CodexSubscription.text(line, timeZone: TimeZone(identifier: "UTC")!), "订阅有效期至 2026/12/12 · 剩 17 天")
    }

    func testRollMonthEndClamp() {
        // 1/31 → 2/28（平年）、2/29（闰年）；锚定原始日，3 月回到 31 日。
        XCTAssertEqual(CodexSubscription.currentPeriodEnd(raw: utc("2027-01-31T10:00:00Z"), now: utc("2027-02-01T00:00:00Z")),
                       utc("2027-02-28T10:00:00Z"))
        XCTAssertEqual(CodexSubscription.currentPeriodEnd(raw: utc("2028-01-31T10:00:00Z"), now: utc("2028-02-01T00:00:00Z")),
                       utc("2028-02-29T10:00:00Z"))
        XCTAssertEqual(CodexSubscription.currentPeriodEnd(raw: utc("2027-01-31T10:00:00Z"), now: utc("2027-03-01T00:00:00Z")),
                       utc("2027-03-31T10:00:00Z"))
        XCTAssertEqual(CodexSubscription.currentPeriodEnd(raw: utc("2026-08-31T00:00:00Z"), now: utc("2026-09-15T00:00:00Z")),
                       utc("2026-09-30T00:00:00Z"))
    }

    func testRollAcrossYear() {
        XCTAssertEqual(CodexSubscription.currentPeriodEnd(raw: utc("2026-11-15T08:00:00Z"), now: utc("2026-12-20T00:00:00Z")),
                       utc("2027-01-15T08:00:00Z"))
        // 正好等于周期末不算「晚于现在」，推到下一个。
        XCTAssertEqual(CodexSubscription.currentPeriodEnd(raw: utc("2026-10-12T08:00:00Z"), now: utc("2026-11-12T08:00:00Z")),
                       utc("2026-12-12T08:00:00Z"))
    }

    func testRollGivesUpAfter48Months() {
        XCTAssertNil(CodexSubscription.currentPeriodEnd(raw: utc("2020-01-01T00:00:00Z"), now: utc("2026-11-24T00:00:00Z")))
        XCTAssertEqual(CodexSubscription.line(raw: utc("2020-01-01T00:00:00Z"), planRaw: "pro", planIsLive: true,
                                              now: utc("2026-11-24T00:00:00Z")), .hidden)
    }

    func testPaidFutureDateUnchanged() {
        let now = utc("2026-11-24T19:00:00Z")
        XCTAssertEqual(CodexSubscription.line(raw: utc("2026-12-12T08:00:00Z"), planRaw: "plus", planIsLive: true, now: now),
                       .active(until: utc("2026-12-12T08:00:00Z"), daysLeft: 17))
    }

    func testLessThanOneDay() {
        let now = utc("2026-11-24T19:00:00Z")
        let line = CodexSubscription.line(raw: utc("2026-11-25T02:10:00Z"), planRaw: "pro", planIsLive: true, now: now)
        XCTAssertEqual(line, .active(until: utc("2026-11-25T02:10:00Z"), daysLeft: 0))
        XCTAssertEqual(CodexSubscription.text(line, timeZone: TimeZone(identifier: "UTC")!), "订阅有效期至 2026/11/25 · 剩不到 1 天")
    }

    func testFreeLivePastIsExpired() {
        let line = CodexSubscription.line(raw: utc("2026-11-20T00:00:00Z"), planRaw: "free", planIsLive: true,
                                          now: utc("2026-11-24T19:00:00Z"))
        XCTAssertEqual(line, .expired)
        XCTAssertEqual(CodexSubscription.text(line), "订阅已过期")
    }

    func testUnsureNeverExpired() {
        let now = utc("2026-11-24T19:00:00Z"), past = utc("2026-11-20T00:00:00Z")
        // 接口失败、id_token 说 free：拿不准，不显示。
        XCTAssertEqual(CodexSubscription.line(raw: past, planRaw: "free", planIsLive: false, now: now), .hidden)
        // 套餐未知（接口失败且 id_token 没套餐，或不认识的套餐）：日期已过去不显示。
        XCTAssertEqual(CodexSubscription.line(raw: past, planRaw: nil, planIsLive: false, now: now), .hidden)
        XCTAssertEqual(CodexSubscription.line(raw: past, planRaw: "mystery", planIsLive: true, now: now), .hidden)
        // 套餐未知但日期在未来：照常显示。
        XCTAssertEqual(CodexSubscription.line(raw: utc("2026-12-12T08:00:00Z"), planRaw: nil, planIsLive: false, now: now),
                       .active(until: utc("2026-12-12T08:00:00Z"), daysLeft: 17))
        // 接口失败、id_token 是付费档：按付费档推算。
        XCTAssertEqual(CodexSubscription.line(raw: utc("2026-10-12T08:00:00Z"), planRaw: "pro", planIsLive: false, now: now),
                       .active(until: utc("2026-12-12T08:00:00Z"), daysLeft: 17))
    }

    func testNoDateHidden() {
        let now = utc("2026-11-24T19:00:00Z")
        for (p, live) in [("pro", true), ("free", true), ("free", false)] {
            XCTAssertEqual(CodexSubscription.line(raw: nil, planRaw: p, planIsLive: live, now: now), .hidden)
        }
        XCTAssertNil(CodexSubscription.text(.hidden))
    }

    func testAccessTokenSubscriptionFallback() {
        func seg(_ o: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: o).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let jwt = seg(["alg": "none"]) + "." + seg(["https://api.openai.com/auth": ["chatgpt_subscription_active_until": 1797062400]]) + ".x"
        XCTAssertEqual(CodexAccount.subscriptionUntil(jwt: jwt), Date(timeIntervalSince1970: 1797062400))
    }

    func testFakeSnapshotDecodesPlanFields() throws {
        let j = #"{"status":"ok","plan":"Pro 200","planRaw":"pro","planIsLive":true}"#
        let s = try JSONDecoder().decode(ServiceSnapshot.self, from: data(j))
        XCTAssertEqual(s.planRaw, "pro"); XCTAssertEqual(s.planIsLive, true)
        let old = try JSONDecoder().decode(ServiceSnapshot.self, from: data(#"{"status":"ok"}"#))
        XCTAssertNil(old.planRaw)
    }

    // MARK: 0.1.2 菜单栏

    func testMenuBarRows() {
        let w = QuotaWindow(kind: .weekly, remainingPercent: 74, resetsAt: nil)
        let f = QuotaWindow(kind: .fiveHour, remainingPercent: 64, resetsAt: nil)
        let ok = ServiceSnapshot(status: .ok, weekly: w, fiveHour: f)
        let off = ServiceSnapshot(status: .notLoggedIn)
        XCTAssertEqual(MenuBarText.rows(codex: ok, gemini: ok).map { $0.service }, [.codex, .gemini])
        XCTAssertEqual(MenuBarText.rows(codex: ok, gemini: ok).first?.secondary, "64")
        XCTAssertEqual(MenuBarText.rows(codex: off, gemini: ok).map { $0.service }, [.gemini])
        XCTAssertEqual(MenuBarText.rows(codex: ok, gemini: ServiceSnapshot(status: .keychainDenied)).map { $0.service }, [.codex])
        XCTAssertTrue(MenuBarText.rows(codex: off, gemini: ServiceSnapshot(status: .apiKeyOnly)).isEmpty)
    }

    #if canImport(AppKit)
    private func row(_ s: Service, _ p: String, _ f: String?) -> MenuBarGroup { MenuBarGroup(service: s, primary: p, secondary: f) }

    func testMenuBarWidthLimits() {
        let both5h = MenuBarLayout.width([row(.codex, "100%", "100"), row(.gemini, "100%", "100")])
        let bothWeekly = MenuBarLayout.width([row(.codex, "100%", nil), row(.gemini, "100%", nil)])
        print("MENUBAR_WIDTH two_rows_5h=\(both5h) two_rows_weekly=\(bothWeekly)")
        XCTAssertLessThanOrEqual(both5h, 75)
        XCTAssertLessThanOrEqual(bothWeekly, 55)
        XCTAssertLessThan(bothWeekly, both5h)
    }

    func testMenuBarWidthStable() {
        let a = MenuBarLayout.width([row(.codex, "9%", "5"), row(.gemini, "100%", nil)])
        let b = MenuBarLayout.width([row(.codex, "100%", "100"), row(.gemini, "100%", "100")])
        let c = MenuBarLayout.width([row(.codex, "--", nil), row(.gemini, "…", "64")])
        XCTAssertEqual(a, b); XCTAssertEqual(b, c)
        XCTAssertEqual(MenuBarLayout.width([row(.codex, "9%", nil)]), MenuBarLayout.width([row(.codex, "100%", nil)]))
    }

    func testSingleRowNoReservedSpace() {
        let single = MenuBarLayout.width([row(.codex, "100%", nil)])
        let single5h = MenuBarLayout.width([row(.gemini, "100%", "100")])
        print("MENUBAR_WIDTH single_weekly=\(single) single_5h=\(single5h)")
        XCTAssertLessThan(single, single5h)          // 没 5 小时不留空
        XCTAssertEqual(MenuBarLayout.style(rowCount: 1).primaryFont.pointSize, 12)
        XCTAssertEqual(MenuBarLayout.style(rowCount: 2).primaryFont.pointSize, 9.5)
        XCTAssertEqual(MenuBarLayout.width([]), 0)
        XCTAssertNil(MenuBarLayout.image([], height: 22))
    }

    func testMenuBarImageIsTemplate() {
        let img = MenuBarLayout.image([row(.codex, "74%", "64"), row(.gemini, "100%", nil)], height: 22)
        XCTAssertNotNil(img)
        XCTAssertTrue(img!.isTemplate)
        XCTAssertEqual(img!.size.height, 22)
    }
    #endif
}

final class GeminiTokenCacheTests: XCTestCase {
    var home: URL!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lanliang-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func cred(_ at: String, rt: String?, expiry: Date?) -> GeminiCredential {
        GeminiCredential(accessToken: at, refreshToken: rt, expiry: expiry, idToken: nil)
    }
    func keychainBlob(_ c: GeminiCredential) -> Data {
        Data((GeminiCredential.keychainPrefix + c.fileData().base64EncodedString()).utf8)
    }
    func perms(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

    final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

    func provider(keychain: Box<GeminiTokenProvider.KeychainRead>, calls: Box<[String]>,
                  respond: @escaping (String) -> (String, Int)) -> GeminiTokenProvider {
        GeminiTokenProvider(home: home, keychain: { keychain.v }, clientID: "cid", clientSecret: "sec",
                            transport: { req in
                                let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                                let rt = URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "refresh_token" }?.value ?? ""
                                calls.v.append(rt)
                                let (b, c) = respond(rt)
                                return (Data(b.utf8), c)
                            }, now: { self.t0 })
    }

    func testFileDataRoundTrip() {
        let c = GeminiCredential(accessToken: "a", refreshToken: "r", expiry: t0, idToken: "i")
        XCTAssertEqual(GeminiCredential.parse(c.fileData()), c)
        XCTAssertEqual(GeminiCredential.parse(keychainBlob(c)), c)
    }

    func testKeychainOnlyWritesCacheOnceThenNeverReadsKeychain() {
        let kc = Box<GeminiTokenProvider.KeychainRead>(.found(keychainBlob(cred("kc-at", rt: "kc-rt", expiry: t0 + 3600))))
        let p = provider(keychain: kc, calls: Box([]), respond: { _ in ("", 500) })
        guard case let .found(c, src) = p.load() else { return XCTFail("应读到") }
        XCTAssertEqual(c.accessToken, "kc-at"); XCTAssertEqual(src, .cache)
        let f = GeminiTokenCache.file(home: home)
        XCTAssertEqual(perms(f), 0o600)
        XCTAssertEqual(perms(GeminiTokenCache.directory(home: home)), 0o700)
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.accessToken, "kc-at")
        // 钥匙串项删掉或拒绝授权后，仍从缓存读到，且不再碰钥匙串。
        kc.v = .denied
        guard case .found(_, .cache) = p.load() else { return XCTFail("应从缓存读到") }
        let p2 = provider(keychain: kc, calls: Box([]), respond: { _ in ("", 500) })
        guard case .found(_, .cache) = p2.load() else { return XCTFail("重启后应从缓存读到") }
        XCTAssertEqual(p.keychainReads, 1); XCTAssertEqual(p2.keychainReads, 0)
        // 没有残留临时文件
        let names = (try? FileManager.default.contentsOfDirectory(atPath: GeminiTokenCache.directory(home: home).path)) ?? []
        XCTAssertEqual(names, ["gemini-token.json"])
    }

    func testAntigravityFileWinsAndIsNeverWritten() async throws {
        let g = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        let fileURL = g.appendingPathComponent("jetski-standalone-oauth-token")
        let original = cred("file-at", rt: "file-rt", expiry: t0 - 10).fileData()
        try original.write(to: fileURL)
        let kc = Box<GeminiTokenProvider.KeychainRead>(.found(keychainBlob(cred("kc-at", rt: "kc-rt", expiry: nil))))
        let p = provider(keychain: kc, calls: Box([]), respond: { _ in (#"{"access_token":"new","expires_in":3600}"#, 200) })
        guard case let .found(c, src) = p.load() else { return XCTFail() }
        XCTAssertEqual(src, .antigravityFile)
        let at = try await p.accessToken(c, source: src)
        XCTAssertEqual(at, "new")
        XCTAssertEqual(try Data(contentsOf: fileURL), original)       // 不写 ~/.gemini
        XCTAssertNil(GeminiTokenCache.read(home: home))               // 不写缓存
        XCTAssertEqual(p.keychainReads, 0)
    }

    func testExpiredCacheRefreshesAndWritesBack() async throws {
        try GeminiTokenCache.write(cred("old-at", rt: "good-rt", expiry: t0 - 10), home: home)
        let kc = Box<GeminiTokenProvider.KeychainRead>(.denied)
        let calls = Box<[String]>([])
        let p = provider(keychain: kc, calls: calls, respond: { _ in (#"{"access_token":"fresh-at","expires_in":3599}"#, 200) })
        guard case let .found(c, src) = p.load() else { return XCTFail() }
        let at = try await p.accessToken(c, source: src)
        XCTAssertEqual(at, "fresh-at")
        XCTAssertEqual(calls.v, ["good-rt"])
        let saved = GeminiTokenCache.read(home: home)
        XCTAssertEqual(saved?.accessToken, "fresh-at")
        XCTAssertEqual(saved?.refreshToken, "good-rt")
        XCTAssertEqual(saved?.expiry, t0 + 3599)
        XCTAssertEqual(perms(GeminiTokenCache.file(home: home)), 0o600)
        XCTAssertEqual(p.keychainReads, 0)   // 不弹钥匙串框
    }

    func testBrokenCacheRefreshRereadsKeychainOnceAndRecovers() async throws {
        try GeminiTokenCache.write(cred("old-at", rt: "broken-rt", expiry: t0 - 10), home: home)
        let kc = Box<GeminiTokenProvider.KeychainRead>(.found(keychainBlob(cred("kc-at", rt: "kc-rt", expiry: t0 - 10))))
        let calls = Box<[String]>([])
        let p = provider(keychain: kc, calls: calls, respond: { rt in
            rt == "kc-rt" ? (#"{"access_token":"recovered","expires_in":3600}"#, 200) : (#"{"error":"invalid_grant"}"#, 400)
        })
        guard case let .found(c, src) = p.load() else { return XCTFail() }
        let at = try await p.accessToken(c, source: src)
        XCTAssertEqual(at, "recovered")
        XCTAssertEqual(calls.v, ["broken-rt", "kc-rt"])
        XCTAssertEqual(p.keychainReads, 1)
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.refreshToken, "kc-rt")
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.accessToken, "recovered")
    }

    func testBrokenCacheAndNoKeychainIsExpiredAndKeychainReadOnlyOnce() async throws {
        try GeminiTokenCache.write(cred("old-at", rt: "broken-rt", expiry: t0 - 10), home: home)
        let kc = Box<GeminiTokenProvider.KeychainRead>(.notFound)
        let p = provider(keychain: kc, calls: Box([]), respond: { _ in (#"{"error":"invalid_grant"}"#, 400) })
        guard case let .found(c, src) = p.load() else { return XCTFail() }
        for _ in 0..<3 {
            do { _ = try await p.accessToken(c, source: src); XCTFail("应过期") }
            catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .expired) }
        }
        XCTAssertEqual(p.keychainReads, 1)   // 本次运行不再反复读钥匙串
        // 文案
        XCTAssertEqual(ServiceSnapshot(status: .loginExpired).message(for: .gemini), "Gemini 登录已过期，打开一次 Antigravity 后再刷新")
    }

    func testSameKeychainContentDoesNotRetry() async throws {
        let same = cred("old-at", rt: "broken-rt", expiry: t0 - 10)
        try GeminiTokenCache.write(same, home: home)
        let kc = Box<GeminiTokenProvider.KeychainRead>(.found(keychainBlob(same)))
        let calls = Box<[String]>([])
        let p = provider(keychain: kc, calls: calls, respond: { _ in (#"{"error":"invalid_grant"}"#, 400) })
        guard case let .found(c, src) = p.load() else { return XCTFail() }
        do { _ = try await p.accessToken(c, source: src); XCTFail() } catch {}
        XCTAssertEqual(calls.v, ["broken-rt"])
    }

    func testNetworkFailureIsNotExpiredAndDoesNotTouchKeychain() async throws {
        try GeminiTokenCache.write(cred("old-at", rt: "rt", expiry: t0 - 10), home: home)
        let p = provider(keychain: Box(.notFound), calls: Box([]), respond: { _ in ("oops", 503) })
        guard case let .found(c, src) = p.load() else { return XCTFail() }
        do { _ = try await p.accessToken(c, source: src); XCTFail() }
        catch { XCTAssertEqual(error as? GeminiTokenProvider.TokenError, .failed) }
        XCTAssertEqual(p.keychainReads, 0)
        XCTAssertEqual(GeminiTokenCache.read(home: home)?.accessToken, "old-at")
    }

    func testNothingAnywhere() {
        XCTAssertEqual(provider(keychain: Box(.notFound), calls: Box([]), respond: { _ in ("", 500) }).load(), .none)
        XCTAssertEqual(provider(keychain: Box(.denied), calls: Box([]), respond: { _ in ("", 500) }).load(), .denied)
        XCTAssertNil(GeminiTokenCache.read(home: home))
    }
}

#if canImport(AppKit)
final class MenuBarBaselineTests: XCTestCase {
    func testBothNumbersShareRowBaseline() {
        // 两行：各行基线是整数点，上行高于下行，且都在 22pt 内。
        let b0 = MenuBarLayout.baseline(rowIndex: 0, rowCount: 2, height: 22)
        let b1 = MenuBarLayout.baseline(rowIndex: 1, rowCount: 2, height: 22)
        XCTAssertEqual(b0, b0.rounded()); XCTAssertEqual(b1, b1.rounded())
        XCTAssertGreaterThan(b0, b1)
        XCTAssertGreaterThanOrEqual(b1, 1)
        XCTAssertLessThanOrEqual(b0 + MenuBarLayout.compact.primaryFont.capHeight, 22)
    }
}
#endif


// MARK: 0.1.4 Gemini 本机 Token 历史

/// 测试里手写 protobuf（只为造合成数据）。
enum PB {
    static func varint(_ v: UInt64) -> Data {
        var v = v, d = Data()
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; d.append(b) } while v != 0
        return d
    }
    static func key(_ n: UInt64, _ t: UInt64) -> Data { varint(n << 3 | t) }
    static func u(_ n: UInt64, _ v: UInt64) -> Data { key(n, 0) + varint(v) }
    static func bytes(_ n: UInt64, _ d: Data) -> Data { key(n, 2) + varint(UInt64(d.count)) + d }
    static func str(_ n: UInt64, _ s: String) -> Data { bytes(n, Data(s.utf8)) }
    static func ts(_ n: UInt64, _ d: Date) -> Data { bytes(n, u(1, UInt64(d.timeIntervalSince1970)) + u(2, 5)) }
    static func usage(input: UInt64 = 0, output: UInt64 = 0, cw: UInt64 = 0, cr: UInt64 = 0, think: UInt64 = 0, resp: UInt64 = 0) -> Data {
        let f: [(UInt64, UInt64)] = [(2, input), (3, output), (4, cw), (5, cr), (9, think), (10, resp)]
        return f.filter { $0.1 > 0 }.reduce(Data()) { $0 + u($1.0, $1.1) }
    }
    static func step(at: Date?, usage: Data?) -> Data {
        (at.map { ts(1, $0) } ?? Data()) + (usage.map { bytes(9, $0) } ?? Data())
    }
    static func gen(usage: Data, lastStep: Int?, model: String = "claude-sonnet-4") -> Data {
        var call = bytes(4, usage) + str(19, model)
        if let l = lastStep { call += bytes(20, str(1, "last_step_index") + str(2, String(l))) }
        call += bytes(20, str(1, "used_claude") + str(2, "true"))
        return bytes(1, call)
    }
}

final class ProtobufTests: XCTestCase {
    func testWireTypes() {
        var d = PB.u(1, 300) + PB.str(2, "hi")
        d += PB.key(3, 1) + Data([1, 0, 0, 0, 0, 0, 0, 0])
        d += PB.key(4, 5) + Data([2, 0, 0, 0])
        d += PB.u(1, 7)                                    // last-wins
        let m = ProtoMessage(d)!
        XCTAssertEqual(m.uint(1), 7); XCTAssertEqual(m.string(2), "hi"); XCTAssertEqual(m.uint(3), 1); XCTAssertEqual(m.uint(4), 2)
        XCTAssertNil(m.uint(9))
    }
    func testInvalid() {
        XCTAssertNil(ProtoMessage(PB.key(1, 2) + PB.varint(10) + Data([1, 2])))   // 截断
        XCTAssertNil(ProtoMessage(PB.key(1, 3)))                                  // group
        XCTAssertNil(ProtoMessage(Data([0x80])))                                  // 半个 varint
        XCTAssertNil(ProtoMessage(PB.key(1, 1) + Data([1, 2, 3])))                // fixed64 不够 8 字节
        XCTAssertNotNil(ProtoMessage(Data()))
    }
    func testTimestamp() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(ProtoMessage(PB.ts(1, t))!.timestamp(1)!.timeIntervalSince1970, 1_795_000_000.000000005, accuracy: 1e-6)
        XCTAssertNil(ProtoMessage(PB.bytes(1, PB.u(1, 0)))!.timestamp(1))
    }
}

final class GeminiHistoryParseTests: XCTestCase {
    let utc = TokenSeries.calendar(timeZone: TimeZone(identifier: "UTC")!)
    let d1 = Date(timeIntervalSince1970: 1_795_000_000)          // 2026-11-18
    var d2: Date { d1.addingTimeInterval(86_400) }

    func testUsageRules() {
        let u = GeminiCallUsage.parse(ProtoMessage(PB.usage(input: 100, cw: 3, cr: 40, think: 5, resp: 7))!)!
        XCTAssertEqual(u.output, 12)                                 // 3 为 0 → 9 + 10
        XCTAssertEqual(u.total, 100 + 12 + 40 + 3)
        XCTAssertEqual(GeminiCallUsage.parse(ProtoMessage(PB.usage(output: 9, think: 5, resp: 7))!)!.output, 9)
        XCTAssertNil(GeminiCallUsage.parse(ProtoMessage(PB.usage(think: 0))!))   // 没有计数不算
        XCTAssertEqual(GeminiCallUsage.tokenTotal(GeminiCallUsage(input: 1, output: 2, cacheWrite: 4, cacheRead: 8)), 15)
    }

    func testStepsOnlyAndGensIgnored() {
        let steps: [(idx: Int64, metadata: Data)] = [
            (0, PB.step(at: d1, usage: nil)),
            (1, PB.step(at: d1, usage: PB.usage(input: 10, output: 5))),
            (2, Data([0xff, 0xff])),                                     // 坏 blob 跳过
            (3, PB.step(at: d2, usage: PB.usage(input: 1, output: 1, cr: 8))),
        ]
        let gens = [PB.gen(usage: PB.usage(input: 999), lastStep: 0)]
        let r = GeminiConversation.records(steps: steps, gens: gens)
        XCTAssertEqual(r.map { $0.usage.total }, [15, 10])
        XCTAssertEqual(GeminiConversation.daily(r, fallback: d1, calendar: utc), ["2026-11-18": 15, "2026-11-19": 10])
    }

    func testFallbackToGenMetadata() {
        let steps: [(idx: Int64, metadata: Data)] = [(0, PB.step(at: d1, usage: nil)), (1, PB.step(at: d2, usage: nil))]
        let gens = [PB.gen(usage: PB.usage(input: 20, think: 2, resp: 3), lastStep: 0),   // 时间 = 第 1 步
                    Data([0x0a, 0x05]),                                              // 坏 blob
                    PB.gen(usage: PB.usage(), lastStep: 0),                          // 没有计数
                    PB.gen(usage: PB.usage(output: 4), lastStep: nil)]               // 没有时间
        let r = GeminiConversation.records(steps: steps, gens: gens)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].at, d2); XCTAssertEqual(r[0].usage.total, 25)
        XCTAssertNil(r[1].at)
        let fallback = d1.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(GeminiConversation.daily(r, fallback: fallback, calendar: utc), ["2026-11-19": 25, "2026-11-15": 4])
    }

    func testDisplay() {
        XCTAssertEqual(GeminiHistory(foundDirectory: false, conversations: 0, failed: 0, daily: [:]).display, .noDirectory)
        XCTAssertEqual(GeminiHistory(foundDirectory: true, conversations: 0, failed: 0, daily: [:]).display, .empty)
        XCTAssertEqual(GeminiHistory(foundDirectory: true, conversations: 2, failed: 0, daily: ["2026-11-18": 0]).display, .empty)
        XCTAssertEqual(GeminiHistory(foundDirectory: true, conversations: 2, failed: 2, daily: [:]).display, .allFailed)
        XCTAssertEqual(GeminiHistory(foundDirectory: true, conversations: 3, failed: 1, daily: ["2026-11-18": 5]).display, .chart(failed: 1))
        XCTAssertEqual(GeminiHistory.message(.noDirectory), "没有找到 Antigravity 本机对话记录")
        XCTAssertEqual(GeminiHistory.message(.empty), "Antigravity 本机暂无 Token 用量")
        XCTAssertEqual(GeminiHistory.message(.allFailed), "Antigravity 对话记录读取失败")
        XCTAssertNil(GeminiHistory.message(.chart(failed: 0)))
    }
}

#if canImport(SQLite3)
import SQLite3

class GeminiDBTestCase: XCTestCase {
    var home: URL!
    let utc = { TokenSeries.calendar(timeZone: TimeZone(identifier: "UTC")!) }
    let d1 = Date(timeIntervalSince1970: 1_795_000_000)          // 2026-11-18 UTC
    var open: [OpaquePointer] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lanliang-agy-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        open.forEach { sqlite3_close($0) }
        try? FileManager.default.removeItem(at: home)
    }

    func dir(_ root: String) -> URL {
        let u = home.appendingPathComponent(".gemini/\(root)/conversations")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 造一个对话库。keepOpen：保持连接不关，最后一批写入只留在 -wal 里（不 checkpoint）。
    @discardableResult
    func makeDB(_ root: String, _ id: String, steps: [Data] = [], gens: [Data] = [], tables: Bool = true,
                walExtra: [Data] = []) -> URL {
        let path = dir(root).appendingPathComponent("\(id).db")
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &h), SQLITE_OK)
        func exec(_ s: String) { XCTAssertEqual(sqlite3_exec(h, s, nil, nil, nil), SQLITE_OK, s) }
        func insert(_ sql: String, _ idx: Int, _ blob: Data) {
            var st: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(h, sql, -1, &st, nil), SQLITE_OK)
            sqlite3_bind_int64(st, 1, Int64(idx))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(st), SQLITE_DONE)
            sqlite3_finalize(st)
        }
        if tables {
            exec("CREATE TABLE steps(idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB)")
            exec("CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB)")
            for (i, s) in steps.enumerated() { insert("INSERT INTO steps(idx, step_type, metadata) VALUES(?, 1, ?)", i, s) }
            for (i, g) in gens.enumerated() { insert("INSERT INTO gen_metadata(idx, data) VALUES(?, ?)", i, g) }
        } else {
            exec("CREATE TABLE other(x)")
        }
        if walExtra.isEmpty {
            sqlite3_close(h)
        } else {
            exec("PRAGMA journal_mode=WAL"); exec("PRAGMA wal_autocheckpoint=0")
            for (i, s) in walExtra.enumerated() {
                insert("INSERT INTO steps(idx, step_type, metadata) VALUES(?, 1, ?)", 1000 + i, s)
            }
            open.append(h!)
        }
        return path
    }

    func step(_ input: UInt64, at: Date?) -> Data { PB.step(at: at, usage: PB.usage(input: input)) }

    func snapshotGemini() -> [String: String] {
        var out: [String: String] = [:]
        let root = home.appendingPathComponent(".gemini")
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        while let u = en?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out[u.path] = "\(v?.fileSize ?? -1)@\(v?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }
        return out
    }

}

final class GeminiHistoryScanTests: GeminiDBTestCase {
    func testNoDirectory() {
        let r = GeminiHistoryScanner(home: home, calendar: utc).scan()
        XCTAssertEqual(r.display, .noDirectory)
    }

    func testStepsGensFailuresAndPB() throws {
        makeDB("antigravity", "a", steps: [step(10, at: d1), step(5, at: d1.addingTimeInterval(86_400))])
        makeDB("antigravity", "b", steps: [PB.step(at: d1, usage: nil)],
               gens: [PB.gen(usage: PB.usage(input: 7, think: 1, resp: 2), lastStep: -1)])   // last_step_index -1 → 无效 → 无时间
        makeDB("antigravity", "bad", tables: false)                                        // 两表都没有 → 失败
        try Data("not sqlite".utf8).write(to: dir("antigravity").appendingPathComponent("junk.db"))  // 坏库 → 失败
        try Data([1, 2, 3]).write(to: dir("antigravity").appendingPathComponent("old.pb"))   // .pb 不计也不算失败
        let s = GeminiHistoryScanner(home: home, calendar: utc)
        let r = s.scan()
        XCTAssertEqual(r.conversations, 4)
        XCTAssertEqual(r.failed, 2)
        XCTAssertEqual(r.daily["2026-11-18"], 10)
        XCTAssertEqual(r.daily["2026-11-19"], 5)
        // b 没有时间：按文件修改时间那天计
        let bDay = DayKey.of(GeminiHistoryScanner.signature(dir("antigravity").appendingPathComponent("b.db").path)!.latest, calendar: utc())
        XCTAssertEqual(r.daily.values.reduce(0, +), 25)
        XCTAssertGreaterThanOrEqual(r.daily[bDay] ?? 0, 10)
        XCTAssertEqual(r.display, .chart(failed: 2))
    }

    func testAllFailed() throws {
        makeDB("antigravity-ide", "x", tables: false)
        XCTAssertEqual(GeminiHistoryScanner(home: home, calendar: utc).scan().display, .allFailed)
    }

    func testEmptyDirectory() {
        _ = dir("antigravity-cli")
        XCTAssertEqual(GeminiHistoryScanner(home: home, calendar: utc).scan().display, .empty)
    }

    func testWalDataIsRead() {
        let p = makeDB("antigravity", "w", steps: [step(1, at: d1)], walExtra: [step(100, at: d1)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.path + "-wal"))
        let r = GeminiHistoryScanner(home: home, calendar: utc).scan()
        XCTAssertEqual(r.daily["2026-11-18"], 101)
        XCTAssertEqual(r.failed, 0)
    }

    func testDedupAndBackupIgnored() throws {
        let old = makeDB("antigravity", "same", steps: [step(1, at: d1)])
        let new = makeDB("antigravity-ide", "same", steps: [step(50, at: d1)])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: new.path)
        makeDB("antigravity-backup", "same", steps: [step(1000, at: d1)])
        makeDB("antigravity-backup", "other", steps: [step(1000, at: d1)])
        let r = GeminiHistoryScanner(home: home, calendar: utc).scan()
        XCTAssertEqual(r.conversations, 1)
        XCTAssertEqual(r.daily["2026-11-18"], 50)
    }

    func testCacheReuseChangeAndRemoval() throws {
        makeDB("antigravity", "a", steps: [step(1, at: d1)])
        let b = makeDB("antigravity", "b", steps: [step(2, at: d1)])
        let s = GeminiHistoryScanner(home: home, calendar: utc)
        XCTAssertEqual(s.scan().daily["2026-11-18"], 3); XCTAssertEqual(s.parseCount, 2)
        XCTAssertEqual(s.scan().daily["2026-11-18"], 3); XCTAssertEqual(s.parseCount, 2)   // 没变：不复制不重读
        // 改动 b：只重读 b
        var h: OpaquePointer?
        sqlite3_open(b.path, &h)
        let blob = step(40, at: d1)
        var st: OpaquePointer?
        sqlite3_prepare_v2(h, "INSERT INTO steps(idx, step_type, metadata) VALUES(9, 1, ?)", -1, &st, nil)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(st, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_step(st); sqlite3_finalize(st); sqlite3_close(h)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: b.path)
        XCTAssertEqual(s.scan().daily["2026-11-18"], 43); XCTAssertEqual(s.parseCount, 3)
        // 删掉 b：结果里消失
        try FileManager.default.removeItem(at: b)
        let r = s.scan()
        XCTAssertEqual(r.daily["2026-11-18"], 1); XCTAssertEqual(r.conversations, 1); XCTAssertEqual(s.parseCount, 3)
    }

    func testOriginalsUntouched() throws {
        makeDB("antigravity", "a", steps: [step(1, at: d1)])
        makeDB("antigravity-ide", "w", steps: [step(1, at: d1)], walExtra: [step(2, at: d1)])
        try Data([9]).write(to: dir("antigravity").appendingPathComponent("legacy.pb"))
        let before = snapshotGemini()
        let s = GeminiHistoryScanner(home: home, calendar: utc)
        _ = s.scan(); _ = s.scan()
        XCTAssertEqual(snapshotGemini(), before)   // 大小、修改时间不变，也没有新文件
    }
}
#endif

// MARK: 0.1.5 跳读解码、磁盘缓存、刻度

final class ProtoScanTests: XCTestCase {
    func scanStep(_ d: Data) -> (at: Date?, usage: GeminiCallUsage?)? { d.withUnsafeBytes { ProtoScan.stepMetadata($0) } }
    func scanGen(_ d: Data) -> (usage: GeminiCallUsage?, step: Int64?)? { d.withUnsafeBytes { ProtoScan.genData($0) } }

    func testSkipsOtherFieldsAndMatchesFullDecoder() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        let big = Data(repeating: 0xAB, count: 100_000)            // 不需要的大字段：只跳过
        let junkNested = PB.bytes(7, Data([0xff, 0xff, 0xff]))     // 子消息本身是坏的，但不解它
        let cases: [Data] = [
            PB.u(2, 5) + PB.bytes(3, big) + PB.ts(1, t) + junkNested + PB.bytes(9, PB.usage(input: 10, output: 2, cr: 3)),
            PB.key(4, 1) + Data([1, 2, 3, 4, 5, 6, 7, 8]) + PB.key(5, 5) + Data([1, 2, 3, 4]) + PB.bytes(9, PB.usage(think: 4, resp: 6)),
            PB.ts(1, t) + PB.ts(1, t.addingTimeInterval(86_400)) + PB.bytes(9, PB.usage(input: 1)) + PB.bytes(9, PB.usage(input: 9)),
            PB.bytes(1, Data([0xff])) + PB.bytes(9, Data([0x80])),     // 时间和用量子消息都坏
            PB.ts(1, t),                                               // 没有用量
            PB.bytes(9, PB.usage()),                                   // 用量全 0
        ]
        for (i, c) in cases.enumerated() {
            let full = ProtoMessage(c)!
            let s = scanStep(c)
            XCTAssertNotNil(s, "case \(i)")
            XCTAssertEqual(s?.at, full.timestamp(1), "case \(i)")
            XCTAssertEqual(s?.usage, full.message(9).flatMap(GeminiCallUsage.parse), "case \(i)")
        }
        XCTAssertEqual(scanStep(cases[1])?.usage?.output, 10)
        XCTAssertEqual(scanStep(cases[2])?.usage?.input, 9)          // 最后一个生效
        // 整条结构坏：跳过这一条
        XCTAssertNil(scanStep(PB.key(1, 2) + PB.varint(50) + Data([1])))
        XCTAssertNil(scanStep(PB.key(3, 3)))
    }

    func testGenData() {
        let g = PB.gen(usage: PB.usage(input: 20, think: 2, resp: 3), lastStep: 4)
        XCTAssertEqual(scanGen(g)?.usage?.total, 25)
        XCTAssertEqual(scanGen(g)?.step, 5)
        XCTAssertNil(scanGen(PB.gen(usage: PB.usage(output: 1), lastStep: nil))?.step)
        XCTAssertNil(scanGen(PB.gen(usage: PB.usage(output: 1), lastStep: -1))?.step)
        XCTAssertNil(scanGen(PB.gen(usage: PB.usage(), lastStep: 1))?.usage)
        XCTAssertNil(scanGen(Data([0x0a, 0x05])))                    // 坏
        XCTAssertNil(scanGen(PB.u(2, 1)))                            // 没有调用信息
    }
}

final class AxisTickTests: XCTestCase {
    func testTicks() {
        XCTAssertEqual(Fmt.axisTokens(9_990_000), "999.00万")
        XCTAssertEqual(Fmt.axisTokens(10_000_000), "1000万")
        XCTAssertEqual(Fmt.axisTokens(44_500_000), "4450万")
        XCTAssertEqual(Fmt.axisTokens(335_000_000), "3.35亿")
        XCTAssertEqual(Fmt.axisTokens(0), "0")
        // 悬停格式不变
        XCTAssertEqual(Fmt.tokens(44_500_000), "4450.00万")
        XCTAssertEqual(Fmt.tokens(9_990_000), "999.00万")
        XCTAssertEqual(Fmt.tokens(335_000_000), "3.35亿")
    }
}

#if canImport(SQLite3)
final class GeminiDiskCacheTests: GeminiDBTestCase {
    var cacheURL: URL { GeminiUsageCacheFile.url(home: home) }

    func perms(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

    func makeSet() {
        makeDB("antigravity", "a", steps: [step(10, at: d1), PB.u(5, 1) + PB.bytes(3, Data(repeating: 1, count: 5000)) + PB.step(at: d1.addingTimeInterval(86_400), usage: PB.usage(input: 7, think: 2, resp: 1))])
        makeDB("antigravity", "fb", steps: [PB.step(at: d1, usage: nil), PB.step(at: d1.addingTimeInterval(2 * 86_400), usage: nil)],
               gens: [PB.gen(usage: PB.usage(input: 20), lastStep: 0), PB.gen(usage: PB.usage(output: 4), lastStep: nil), Data([0x0a, 0x05])])
        makeDB("antigravity-ide", "w", steps: [step(1, at: d1)], walExtra: [step(100, at: d1), Data([0xff, 0xff])])
        makeDB("antigravity-cli", "bad", tables: false)
    }

    func testV014AndV015SameDaily() throws {
        makeSet()
        let s = GeminiHistoryScanner(home: home, calendar: utc)
        let r = s.scan()
        // 0.1.4 读法逐库算一遍
        var v014: [String: Int64] = [:]
        var failed = 0
        for e in s.list().entries {
            let sig = GeminiHistoryScanner.signature(e.path.path)!
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("v014-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let db = tmp.appendingPathComponent("c.db")
            try FileManager.default.copyItem(at: e.path, to: db)
            if FileManager.default.fileExists(atPath: e.path.path + "-wal") {
                try FileManager.default.copyItem(atPath: e.path.path + "-wal", toPath: db.path + "-wal")
            }
            guard let rows = GeminiHistoryScanner.readRowsV014(db.path) else { failed += 1; continue }
            let recs = GeminiConversation.records(steps: rows.steps, gens: rows.gens)
            for (k, v) in GeminiConversation.daily(recs, fallback: sig.latest, calendar: utc()) { v014[k, default: 0] += v }
        }
        XCTAssertEqual(r.daily, v014)
        XCTAssertEqual(r.failed, failed)
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(r.daily["2026-11-18"], 10 + 101)
        XCTAssertEqual(r.daily["2026-11-19"], 10)
        XCTAssertEqual(r.daily["2026-11-20"], 20)
    }

    func testDiskCacheRoundTrip() throws {
        makeSet()
        let s1 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
        XCTAssertNil(s1.loadDiskCache())
        let r1 = s1.scan()
        XCTAssertEqual(perms(cacheURL), 0o600)
        XCTAssertEqual(perms(cacheURL.deletingLastPathComponent()), 0o700)
        let file = GeminiUsageCacheFile.load(cacheURL)!
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.entries.count, 3)                                    // 读取失败的不进缓存
        XCTAssertFalse(file.entries.keys.contains { $0.hasSuffix("bad.db") })
        XCTAssertEqual(file.entries.first { $0.key.hasSuffix("/a.db") }?.value.walSize, 0)
        XCTAssertEqual(file.entries.first { $0.key.hasSuffix("/a.db") }?.value.walMtime, 0)
        let text = String(data: try Data(contentsOf: cacheURL), encoding: .utf8)!
        XCTAssertFalse(text.contains("last_step_index"))

        // 新的扫描器（模拟重启）：先用缓存立即出图，扫描时没变的 0 复制 0 打开（失败的库重试）
        let s2 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
        let cached = s2.loadDiskCache()!
        XCTAssertEqual(cached.daily, r1.daily)
        let r2 = s2.scan()
        XCTAssertEqual(r2, r1)
        XCTAssertEqual(s2.copyCount, 1); XCTAssertEqual(s2.openCount, 1)       // 只有 bad.db 重试
        let mtime = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date

        // 删掉 bad：再扫 0 复制 0 打开，缓存内容没变不重写
        try FileManager.default.removeItem(at: dir("antigravity-cli").appendingPathComponent("bad.db"))
        let s3 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
        let r3 = s3.scan()
        XCTAssertEqual(s3.copyCount, 0); XCTAssertEqual(s3.openCount, 0)
        XCTAssertEqual(r3.failed, 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date, mtime)

        // 改一个库只重读那一个；删掉一个库从缓存和结果里消失
        let a = dir("antigravity").appendingPathComponent("a.db")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 30)], ofItemAtPath: a.path)
        try FileManager.default.removeItem(at: dir("antigravity").appendingPathComponent("fb.db"))
        let s4 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
        let r4 = s4.scan()
        XCTAssertEqual(s4.openCount, 1)
        XCTAssertEqual(r4.conversations, 2)
        XCTAssertNil(r4.daily["2026-11-20"])
        XCTAssertEqual(GeminiUsageCacheFile.load(cacheURL)!.entries.count, 2)
        XCTAssertFalse(GeminiUsageCacheFile.load(cacheURL)!.entries.keys.contains { $0.hasSuffix("fb.db") })
        // 没有残留临时文件
        let names = try FileManager.default.contentsOfDirectory(atPath: cacheURL.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["gemini-usage-cache.json"])
    }

    func testDebugTimingWritesTempCacheInSubfolder() throws {
        makeSet()
        try FileManager.default.removeItem(at: dir("antigravity-cli").appendingPathComponent("bad.db"))
        let root = home.appendingPathComponent("tmp-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let x = GeminiScanTiming.run(home: home, tempRoot: root, calendar: utc)
        XCTAssertTrue(x.cacheWritten)
        XCTAssertEqual(x.failed, 0)
        XCTAssertGreaterThan(x.firstOpened, 0)
        XCTAssertEqual(x.cachedOpened, 0)
        XCTAssertTrue(GeminiScanTiming.lines(x)[0].hasSuffix("cacheWritten=yes"))
        XCTAssertTrue(GeminiScanTiming.lines(x)[1].hasSuffix("opened=0"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])   // 子目录已删
    }

    func testBadCacheFilesMeanNoCache() throws {
        makeSet()
        let expected = GeminiHistoryScanner(home: home, calendar: utc).scan()
        let bad: [Data?] = [Data("{not json".utf8),
                            Data(#"{"version":2,"entries":{}}"#.utf8),
                            Data(#"{"version":1}"#.utf8),
                            nil]
        for b in bad {
            try? FileManager.default.removeItem(at: cacheURL)
            if let b = b {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try b.write(to: cacheURL)
            }
            let s = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
            XCTAssertNil(s.loadDiskCache())
            XCTAssertEqual(s.scan(), expected)
            XCTAssertEqual(s.openCount, 4)                                         // 从头扫描
            XCTAssertEqual(GeminiUsageCacheFile.load(cacheURL)?.entries.count, 3)  // 覆盖写
            XCTAssertEqual(perms(cacheURL), 0o600)
        }
    }

    func testCachedStartTiming() {
        // 合成 40 个库、每库 300 步，测一次完整扫描和有缓存的重扫。
        for i in 0..<40 {
            makeDB("antigravity", "t\(i)", steps: (0..<300).map { j in
                PB.u(2, 1) + PB.bytes(3, Data(repeating: 7, count: 2000)) + PB.step(at: d1.addingTimeInterval(Double(j) * 600), usage: PB.usage(input: 100, output: 5, cr: 30))
            })
        }
        let s = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
        let full = s.scan()
        let t = s.lastTimings
        let s2 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: utc)
        let t0 = CFAbsoluteTimeGetCurrent()
        let cached = s2.loadDiskCache()
        let tLoad = CFAbsoluteTimeGetCurrent() - t0
        _ = s2.scan()
        print(String(format: "GEMINI_SCAN_TIMING dbs=40 rows=12000 full=%.3fs copy=%.3fs sqlite=%.3fs decode=%.3fs cache_load=%.4fs cached_rescan=%.4fs",
                     t.total, t.copy, t.sqlite, t.decode, tLoad, s2.lastTimings.total))
        XCTAssertEqual(cached?.daily, full.daily)
        XCTAssertEqual(s2.openCount, 0)
        XCTAssertLessThan(tLoad, 1)
    }
}
#endif

// MARK: 0.1.5 §5 额度先出、不读 Codex 本机日志

final class RefreshCoordinatorTests: XCTestCase {
    func testQuotaNotBlockedBySlowScanOrHungService() {
        // Gemini 本机扫描人为延迟 10 秒（在自己的后台队列上），不影响额度。
        let flags = Flags()
        DispatchQueue(label: "test.scan", qos: .userInitiated).async { Thread.sleep(forTimeInterval: 10); flags.set("scan") }
        let codexArrived = expectation(description: "codex")
        let start = Date()
        var codexDelay: TimeInterval = -1
        RefreshCoordinator.run(
            codex: { try? await Task.sleep(nanoseconds: 100_000_000); return "codex" },
            gemini: { try? await Task.sleep(nanoseconds: 60_000_000_000); return "gemini" },   // 卡住
            onCodex: { v in XCTAssertEqual(v, "codex"); codexDelay = Date().timeIntervalSince(start); codexArrived.fulfill() },
            onGemini: { _ in flags.set("gemini") },
            onAllDone: { flags.set("done") })
        wait(for: [codexArrived], timeout: 2)
        XCTAssertLessThan(codexDelay, 1.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(flags.has("gemini")); XCTAssertFalse(flags.has("done")); XCTAssertFalse(flags.has("scan"))
    }

    final class Flags {
        private let lock = NSLock(); private var s = Set<String>()
        func set(_ k: String) { lock.lock(); s.insert(k); lock.unlock() }
        func has(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return s.contains(k) }
    }

    func testEachDeliveredIndependentlyThenAllDone() {
        let g = expectation(description: "gemini first"), c = expectation(description: "codex"), d = expectation(description: "done")
        var order: [String] = []
        RefreshCoordinator.run(
            codex: { try? await Task.sleep(nanoseconds: 300_000_000); return 1 },
            gemini: { return 2 },
            onCodex: { _ in order.append("codex"); c.fulfill() },
            onGemini: { _ in order.append("gemini"); g.fulfill() },
            onAllDone: { order.append("done"); d.fulfill() })
        wait(for: [g, c, d], timeout: 3, enforceOrder: true)
        XCTAssertEqual(order, ["gemini", "codex", "done"])
    }

    func testCodexReadsOnlyAuthJSON() {
        let paths = CodexCredential.readPaths(env: ["CODEX_HOME": "/tmp/codex-home"])
        XCTAssertEqual(paths.map { $0.path }, ["/tmp/codex-home/auth.json"])
        XCTAssertFalse(paths.contains { $0.path.contains("sessions") })
    }
}

final class PanelTextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUpdatedAgo() {
        XCTAssertEqual(PanelText.updated(last: now.addingTimeInterval(-10), now: now, refreshing: false), "刚刚更新")
        XCTAssertEqual(PanelText.updated(last: now.addingTimeInterval(-60), now: now, refreshing: false), "1 分钟前更新")
        XCTAssertEqual(PanelText.updated(last: now.addingTimeInterval(-59 * 60 - 59), now: now, refreshing: false), "59 分钟前更新")
        XCTAssertEqual(PanelText.updated(last: now.addingTimeInterval(-3_600), now: now, refreshing: false), "1 小时前更新")
        XCTAssertEqual(PanelText.updated(last: now, now: now, refreshing: true), "正在刷新…")
        XCTAssertEqual(PanelText.updated(last: nil, now: now, refreshing: false), "")
        XCTAssertEqual(PanelText.ago(last: now.addingTimeInterval(-300), now: now), "5 分钟前")
    }

    func testTabValue() {
        let w = QuotaWindow(kind: .weekly, remainingPercent: 77, resetsAt: nil)
        let f = QuotaWindow(kind: .fiveHour, remainingPercent: 64, resetsAt: nil)
        XCTAssertEqual(PanelText.tabPercent(ServiceSnapshot(status: .ok, weekly: w, fiveHour: f)), "77%")
        XCTAssertEqual(PanelText.tabPercent(ServiceSnapshot(status: .ok, fiveHour: f)), "64%")
        XCTAssertEqual(PanelText.tabWindow(ServiceSnapshot(status: .ok, fiveHour: f))?.kind, .fiveHour)
        XCTAssertEqual(PanelText.tabPercent(ServiceSnapshot(status: .ok)), "—")
        XCTAssertEqual(PanelText.tabPercent(ServiceSnapshot(status: .notLoggedIn, weekly: w)), "—")
        XCTAssertEqual(PanelText.tabPercent(ServiceSnapshot(status: .fetchFailed, weekly: w)), "77%")   // 失败保留上次值
    }
}

// MARK: 0.3.0 监听服务与消耗汇总

final class ServiceSelectionTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "lanliang.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testDefaultsBothOnAndPersist() {
        let (d, name) = freshDefaults()
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(ServiceSelection.load(from: d), ServiceSelection(codex: true, gemini: true))
        let codexOnly = ServiceSelection.all.setting(.gemini, on: false)
        codexOnly.save(to: d)
        XCTAssertEqual(d.object(forKey: "monitor.codex") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "monitor.gemini") as? Bool, false)
        XCTAssertEqual(ServiceSelection.load(from: d), codexOnly)
        XCTAssertEqual(ServiceSelection.load(from: d).enabled, [.codex])
        XCTAssertTrue(ServiceSelection.load(from: d).isSingle)
        XCTAssertFalse(ServiceSelection.all.isSingle)
        XCTAssertEqual(ServiceSelection.all.enabled, [.codex, .gemini])
    }

    func testLastEnabledCannotBeTurnedOff() {
        let (d, name) = freshDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let geminiOnly = ServiceSelection(codex: false, gemini: true)
        geminiOnly.save(to: d)
        XCTAssertFalse(geminiOnly.canToggle(.gemini))
        XCTAssertTrue(geminiOnly.canToggle(.codex))
        XCTAssertTrue(ServiceSelection.all.canToggle(.codex))
        XCTAssertTrue(ServiceSelection.all.canToggle(.gemini))
        // 关不掉：结果不变，偏好也不变
        let after = geminiOnly.setting(.gemini, on: false)
        XCTAssertEqual(after, geminiOnly)
        XCTAssertEqual(ServiceSelection.load(from: d), geminiOnly)
        // 两个都关的旧偏好按两个都开
        d.set(false, forKey: "monitor.codex"); d.set(false, forKey: "monitor.gemini")
        XCTAssertEqual(ServiceSelection.load(from: d), ServiceSelection.all)
        XCTAssertEqual(ServiceSelection(codex: false, gemini: false), ServiceSelection.all)
        // 重新打开
        XCTAssertEqual(geminiOnly.setting(.codex, on: true), ServiceSelection.all)
    }

    func testDebugParse() {
        XCTAssertEqual(ServiceSelection.parse("codex"), ServiceSelection(codex: true, gemini: false))
        XCTAssertEqual(ServiceSelection.parse("gemini"), ServiceSelection(codex: false, gemini: true))
        XCTAssertEqual(ServiceSelection.parse("codex,gemini"), ServiceSelection.all)
        XCTAssertNil(ServiceSelection.parse("foo"))
        XCTAssertEqual(ServiceSelection.parse("gemini")?.debugText, "gemini")
        XCTAssertEqual(ServiceSelection.all.debugText, "codex,gemini")
    }

    func testMenuBarRowsHideDisabled() {
        let w = QuotaWindow(kind: .weekly, remainingPercent: 77, resetsAt: nil)
        let c = ServiceSnapshot(status: .ok, weekly: w), g = ServiceSnapshot(status: .ok, weekly: w)
        XCTAssertEqual(MenuBarText.rows(codex: c, gemini: g, selection: .all).map { $0.service }, [.codex, .gemini])
        XCTAssertEqual(MenuBarText.rows(codex: c, gemini: g, selection: ServiceSelection(codex: true, gemini: false)).map { $0.service }, [.codex])
        XCTAssertEqual(MenuBarText.rows(codex: c, gemini: g, selection: ServiceSelection(codex: false, gemini: true)).map { $0.service }, [.gemini])
        // 只开 Codex 但没登录 → 栏量图标
        XCTAssertTrue(MenuBarText.rows(codex: ServiceSnapshot(status: .notLoggedIn), gemini: g,
                                       selection: ServiceSelection(codex: true, gemini: false)).isEmpty)
        XCTAssertEqual(MenuBarText.rows(codex: c, gemini: g), MenuBarText.rows(codex: c, gemini: g, selection: .all))
    }

    func testAccountLine() {
        let s = ServiceSnapshot(status: .ok, email: "allen@verylongcompanydomain.com", plan: "Google AI Ultra")
        XCTAssertEqual(SettingsText.accountLine(service: .gemini, snap: s), "已登录 · Google AI Ultra · a***@verylongcompanydomain.com")
        XCTAssertEqual(SettingsText.accountLine(service: .codex, snap: ServiceSnapshot(status: .notLoggedIn)), "未检测到登录")
        XCTAssertEqual(SettingsText.accountLine(service: .codex, snap: ServiceSnapshot(status: .loading), isOn: false), "已关闭")
        XCTAssertEqual(SettingsText.keepOneHint, "至少保留一个服务，最后一个开关不能关。")
    }

    #if canImport(AppKit)
    func testLargeMenuBarStyle() {
        let r = [MenuBarGroup(service: .codex, primary: "100%", secondary: "100")]
        XCTAssertEqual(MenuBarLayout.style(rowCount: 1, large: true).primaryFont.pointSize, 14)
        XCTAssertEqual(MenuBarLayout.style(rowCount: 1, large: true).secondaryFont.pointSize, 11)
        XCTAssertEqual(MenuBarLayout.style(rowCount: 1, large: true).iconPoint, 15)
        XCTAssertEqual(MenuBarLayout.style(rowCount: 2, large: true).primaryFont.pointSize, 9.5)   // 两行不放大
        let large = MenuBarLayout.width(r, large: true), normal = MenuBarLayout.width(r)
        print("MENUBAR_WIDTH large_single_5h=\(large) single_5h=\(normal)")
        XCTAssertGreaterThan(large, normal)
        // 宽度只按最长文案定，数字变化不跳
        XCTAssertEqual(MenuBarLayout.width([MenuBarGroup(service: .codex, primary: "8%", secondary: "5")], large: true), large)
        XCTAssertNotNil(MenuBarLayout.image(r, height: 22, large: true))
    }
    #endif
}

final class UsageSummaryTests: XCTestCase {
    let official: [String: Int64] = ["2026-11-01": 19_000_000_000, "2026-11-02": 300_000_000]
    let gemini = GeminiHistory(foundDirectory: true, conversations: 3, failed: 0,
                               daily: ["2026-05-21": 400_000_000, "2026-11-24": 69_000_000])

    func testBothServices() {
        let s = UsageSummary.make(selection: .all, official: official, officialLoaded: true, gemini: gemini)
        XCTAssertFalse(s.loading); XCTAssertFalse(s.incomplete)
        XCTAssertEqual(s.total, 19_769_000_000)
        XCTAssertEqual(Fmt.tokens(s.total!), "197.69亿")
        XCTAssertTrue(s.showsSplit)
        XCTAssertEqual(s.items.map { $0.service }, [.codex, .gemini])
        XCTAssertEqual(s.items[0].tokens, 19_300_000_000)
        XCTAssertEqual(s.items[1].tokens, 469_000_000)
        XCTAssertEqual(UsageSummary.percent(s.items[0].share!), "97.6%")
        XCTAssertEqual(UsageSummary.percent(s.items[1].share!), "2.4%")
        XCTAssertEqual(Fmt.tokens(999_999_000_000), "9999.99亿")
    }

    func testSingleService() {
        let c = UsageSummary.make(selection: ServiceSelection(codex: true, gemini: false), official: official,
                                  officialLoaded: true, gemini: gemini)
        XCTAssertEqual(c.total, 19_300_000_000)
        XCTAssertEqual(c.items.count, 1)
        XCTAssertFalse(c.showsSplit)
        XCTAssertNil(c.items[0].share)
        let g = UsageSummary.make(selection: ServiceSelection(codex: false, gemini: true), official: nil,
                                  officialLoaded: false, gemini: gemini)
        XCTAssertEqual(g.total, 469_000_000)
        XCTAssertFalse(g.loading)   // Codex 关掉时不等它
        XCTAssertFalse(g.incomplete)
    }

    func testCodexFailedOnlyCountsGemini() {
        let s = UsageSummary.make(selection: .all, official: nil, officialLoaded: true, gemini: gemini)
        XCTAssertTrue(s.incomplete)
        XCTAssertFalse(s.loading)
        XCTAssertEqual(s.total, 469_000_000)
        XCTAssertEqual(Fmt.tokens(s.total!), "4.69亿")
        XCTAssertEqual(s.items[0].state, .unavailable)
        XCTAssertNil(s.items[0].tokens)
        XCTAssertFalse(s.showsSplit)
        XCTAssertNil(s.items[1].share)
        XCTAssertEqual(SettingsText.unavailable(.codex), "官方用量暂时拿不到")
        // 只开 Codex 且失败：没有可显示的数
        let only = UsageSummary.make(selection: ServiceSelection(codex: true, gemini: false), official: nil,
                                     officialLoaded: true, gemini: nil)
        XCTAssertTrue(only.incomplete)
        XCTAssertNil(only.total)
    }

    func testGeminiAllFailedIncomplete() {
        let bad = GeminiHistory(foundDirectory: true, conversations: 2, failed: 2, daily: [:])
        let s = UsageSummary.make(selection: .all, official: official, officialLoaded: true, gemini: bad)
        XCTAssertTrue(s.incomplete)
        XCTAssertEqual(s.total, 19_300_000_000)
        XCTAssertEqual(s.items[1].state, .unavailable)
        // 没有目录 / 没有用量：算 0，不算失败
        let none = GeminiHistory(foundDirectory: false, conversations: 0, failed: 0, daily: [:])
        let t = UsageSummary.make(selection: .all, official: official, officialLoaded: true, gemini: none)
        XCTAssertFalse(t.incomplete)
        XCTAssertEqual(t.total, 19_300_000_000)
    }

    func testLoading() {
        let s = UsageSummary.make(selection: .all, official: nil, officialLoaded: false, gemini: gemini)
        XCTAssertTrue(s.loading)
        XCTAssertNil(s.total)          // 不显示 0
        XCTAssertFalse(s.showsSplit)
        XCTAssertEqual(s.items[0].state, .loading)
        let g = UsageSummary.make(selection: .all, official: official, officialLoaded: true, gemini: nil)
        XCTAssertTrue(g.loading)
        XCTAssertNil(g.total)
    }
}

final class DisabledServiceRequestTests: XCTestCase {
    final class Counter {
        private let lock = NSLock(); private var n: [String: Int] = [:]
        func hit(_ k: String) { lock.lock(); n[k, default: 0] += 1; lock.unlock() }
        func count(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return n[k] ?? 0 }
    }

    func testDisabledServiceNotRequested() {
        let counter = Counter()
        let done = expectation(description: "done")
        RefreshCoordinator.run(
            codex: { counter.hit("codex-request"); return 1 },
            gemini: { counter.hit("gemini-request"); return 2 },
            selection: ServiceSelection(codex: false, gemini: true),
            onCodex: { _ in counter.hit("codex-deliver") },
            onGemini: { _ in counter.hit("gemini-deliver") },
            onAllDone: { done.fulfill() })
        wait(for: [done], timeout: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(counter.count("codex-request"), 0)
        XCTAssertEqual(counter.count("codex-deliver"), 0)
        XCTAssertEqual(counter.count("gemini-request"), 1)
        XCTAssertEqual(counter.count("gemini-deliver"), 1)
    }

    func testOnlyCodexEnabled() {
        let counter = Counter()
        let done = expectation(description: "done")
        RefreshCoordinator.run(
            codex: { counter.hit("codex-request"); return 1 },
            gemini: { counter.hit("gemini-request"); return 2 },
            selection: ServiceSelection(codex: true, gemini: false),
            onCodex: { _ in counter.hit("codex-deliver") },
            onGemini: { _ in counter.hit("gemini-deliver") },
            onAllDone: { done.fulfill() })
        wait(for: [done], timeout: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(counter.count("codex-request"), 1)
        XCTAssertEqual(counter.count("gemini-request"), 0)
        XCTAssertEqual(counter.count("gemini-deliver"), 0)
    }
}

// MARK: 0.3.1 消耗汇总堆叠柱

final class StackedSeriesTests: XCTestCase {
    let cal = TokenSeries.calendar(timeZone: TimeZone(identifier: "UTC")!)
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))! }
    let codex: [String: Int64] = ["2026-11-25": 320_000_000, "2026-11-24": 100_000_000, "2026-10-01": 5_000]
    let gemini: [String: Int64] = ["2026-11-25": 40_000_000, "2026-11-23": 7_000]

    func testDailyStacksBothServices() {
        let s = StackedSeries.bars(range: .daily, codex: codex, gemini: gemini, now: now, calendar: cal)
        XCTAssertEqual(s.count, 30)
        let last = s.last!
        XCTAssertEqual(last.bar.key, "2026-11-25")
        XCTAssertEqual(last.codex, 320_000_000)
        XCTAssertEqual(last.gemini, 40_000_000)
        XCTAssertEqual(last.total, 360_000_000)
        XCTAssertEqual(last.bar.value, 360_000_000)   // 坐标轴和悬停用合计
        XCTAssertEqual(s[28].codex, 100_000_000); XCTAssertEqual(s[28].gemini, 0)
        XCTAssertEqual(s[27].codex, 0); XCTAssertEqual(s[27].gemini, 7_000)
        // 和面板单服务柱子的区间完全一致
        let panel = TokenSeries.bars(range: .daily, official: nil, local: codex, now: now, calendar: cal)
        XCTAssertEqual(s.map { $0.bar.key }, panel.map { $0.key })
        XCTAssertEqual(s.map { $0.codex }, panel.map { $0.value })
    }

    func testMonthlyAndWeeklyMerge() {
        let m = StackedSeries.bars(range: .monthly, codex: codex, gemini: gemini, now: now, calendar: cal)
        XCTAssertEqual(m.count, 6)
        XCTAssertEqual(m.last!.codex, 420_000_000)
        XCTAssertEqual(m.last!.gemini, 40_007_000)
        XCTAssertEqual(m[m.count - 2].codex, 5_000)
        let w = StackedSeries.bars(range: .weekly, codex: codex, gemini: gemini, now: now, calendar: cal)
        XCTAssertEqual(w.count, 12)
        // 周一开始：11/23 是周一，本周 = 11/23–11/29
        XCTAssertEqual(w.last!.bar.key, "2026-11-23")
        XCTAssertEqual(w.last!.total, 420_000_000 + 40_007_000)
        let sumAll = m.map { $0.total }.reduce(0, +)
        XCTAssertEqual(sumAll, codex.values.reduce(0, +) + gemini.values.reduce(0, +))
    }

    func testMissingServiceDrawsOnlyTheOther() {
        // Codex 失败（nil）：只剩 Gemini 段
        let s = StackedSeries.bars(range: .daily, codex: nil, gemini: gemini, now: now, calendar: cal)
        XCTAssertEqual(s.last!.codex, 0)
        XCTAssertEqual(s.last!.total, 40_000_000)
        let only = StackedSeries.bars(range: .daily, codex: codex, gemini: nil, now: now, calendar: cal)
        XCTAssertEqual(only.last!.total, 320_000_000)
    }

    func testTipLines() {
        let s = StackedSeries.bars(range: .daily, codex: codex, gemini: gemini, now: now, calendar: cal).last!
        XCTAssertEqual(StackedSeries.tipLines(s), ["11月25日", "Codex 3.20亿", "Gemini 4000.00万", "合计 3.60亿 Tokens"])
    }

    func testAxisMaxIsLargestTotal() {
        let s = StackedSeries.bars(range: .daily, codex: codex, gemini: gemini, now: now, calendar: cal)
        XCTAssertEqual(StackedSeries.axisMax(s), 360_000_000)
        XCTAssertEqual(StackedSeries.axisMax(s), s.map { $0.bar.value }.max())
        XCTAssertEqual(StackedSeries.axisMax([]), 1)
        // 最长刻度：99.99亿
        let big = StackedSeries.bars(range: .daily, codex: ["2026-11-25": 9_000_000_000], gemini: ["2026-11-25": 999_000_000],
                                     now: now, calendar: cal)
        XCTAssertEqual(Fmt.axisTokens(StackedSeries.axisMax(big)), "99.99亿")
    }

    func testStackSumsEqualTotalForEachRange() {
        for r in TokenRange.allCases {
            let s = StackedSeries.bars(range: r, codex: codex, gemini: gemini, now: now, calendar: cal)
            let c = TokenSeries.bars(range: r, official: nil, local: codex, now: now, calendar: cal)
            let g = TokenSeries.bars(range: r, official: nil, local: gemini, now: now, calendar: cal)
            for i in s.indices {
                XCTAssertEqual(s[i].codex + s[i].gemini, s[i].total)
                XCTAssertEqual(s[i].total, c[i].value + g[i].value)
            }
        }
    }
}
