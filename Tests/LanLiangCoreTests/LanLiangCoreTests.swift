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
        XCTAssertEqual(MenuBarText.group(for: .codex, state: .ok(weekly: w, fiveHour: nil)),
                       MenuBarGroup(service: .codex, primary: "77%", secondary: nil))
        XCTAssertEqual(MenuBarText.group(for: .gemini, state: .ok(weekly: w, fiveHour: f))?.secondary, "64%")
        XCTAssertNil(MenuBarText.group(for: .codex, state: .notLoggedIn))
        XCTAssertNil(MenuBarText.group(for: .codex, state: .apiKeyOnly))
        XCTAssertEqual(MenuBarText.group(for: .codex, state: .fetchFailed)?.primary, "--")
        XCTAssertEqual(MenuBarText.group(for: .gemini, state: .loginExpired)?.primary, "--")
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
