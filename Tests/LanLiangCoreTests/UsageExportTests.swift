import XCTest
@testable import LanLiangCore

final class UsageExportTests: XCTestCase {
    func testSelectedScopeFiltersTokenBarsAndModelSharesAndRedactsLabels() throws {
        let calendar = TokenSeries.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26)))
        let bars = StackedSeries.bars(range: .monthly, codex: ["2026-10-01": 99, "2026-11-20": 4],
                                     gemini: ["2026-11-25": 6], now: now, calendar: calendar)
        let snapshot = UsageExportSnapshot(range: .monthly, bars: bars,
            selection: ModelPeriodSelection(key: "2026-11-01"), now: now, calendar: calendar,
            groups: [(.codex, true, ["2026-10-01": ["old": 99],
                "2026-11-20": ["gpt": 2, "person@example.com": 1, "projects/p/customer/c": 1],
                "2026-11-27": ["future": 5]]), (.gemini, true, nil)])
        XCTAssertEqual(snapshot.bars.map(\.bar.key), ["2026-11-01"])
        XCTAssertEqual(snapshot.total, 10)
        XCTAssertEqual(snapshot.dateText, "2026-11-01 至 2026-11-26")
        XCTAssertEqual(snapshot.groups[0].shares?.map(\.name), ["gpt", ModelDistribution.unknown])
        XCTAssertEqual(snapshot.groups[0].shares?.map(\.tenths), [500, 500])
        XCTAssertNil(snapshot.groups[1].shares)
    }

    func testUnselectedUsesAllDisplayedBarsAndPreservesAvailableButEmpty() throws {
        let calendar = TokenSeries.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26)))
        let bars = StackedSeries.bars(range: .daily, codex: ["2026-08-01": 99, "2026-11-22": 4],
                                     gemini: nil, now: now, calendar: calendar)
        let snapshot = UsageExportSnapshot(range: .daily, bars: bars, selection: ModelPeriodSelection(),
            now: now, calendar: calendar, groups: [(.codex, true, [:]), (.gemini, false, nil)])
        XCTAssertEqual(snapshot.bars.count, 30)
        XCTAssertEqual(snapshot.total, 4)
        XCTAssertEqual(snapshot.groups[0].shares, [])
        XCTAssertFalse(snapshot.groups[1].hasTokenData)
    }
}
