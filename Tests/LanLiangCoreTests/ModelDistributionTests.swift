import XCTest
@testable import LanLiangCore
#if canImport(SQLite3)
import SQLite3
#endif

final class ModelDistributionTests: XCTestCase {
    func testPeriodsUnknownAndRounding() {
        let days: DailyModelWeights = [
            "2026-11-01": ["sol": 3, "luna": 4],
            "2026-11-24": ["sol": 1, "luna": 1, ModelDistribution.unknown: 1],
            "2026-11-25": ["future": 120]
        ]
        let daily = ModelDistribution.shares(days, start: "2026-11-24", through: "2026-11-24")
        XCTAssertEqual(daily.map(\.name), ["luna", "sol", "未知模型"])
        XCTAssertEqual(daily.map(\.tenths), [334, 333, 333])
        let longer = ModelDistribution.shares(days, start: "2026-11-01", through: "2026-11-24", maxNamedModels: 1)
        XCTAssertEqual(longer.map(\.name), ["luna", "其他模型", "未知模型"])
        XCTAssertEqual(longer.map(\.tenths), [500, 400, 100])
        XCTAssertEqual(longer.map(\.tenths).reduce(0, +), 1000)
        XCTAssertTrue(ModelDistribution.shares(days, start: "2026-11-26", through: "2026-12-01").isEmpty)
    }

    func testAntigravityGenerationFields() {
        let at = Date(timeIntervalSince1970: 1_795_531_200)
        let id = Data(repeating: 9, count: 16)
        let call = PB.bytes(4, PB.usage(input: 56, output: 44)) + PB.str(19, "gemini-pro-default")
            + PB.str(21, "Gemini 3 Pro") + PB.bytes(9, PB.ts(4, at))
        let b = PB.bytes(1, call) + PB.bytes(4, id)
        let g = b.withUnsafeBytes { ProtoScan.genData($0) }
        XCTAssertEqual(g?.model, "Gemini 3 Pro")
        XCTAssertEqual(g?.usage?.total, 100)
        XCTAssertEqual(g?.generationID, id)
        XCTAssertEqual(g?.at?.timeIntervalSince1970, at.timeIntervalSince1970)
        let fallback = PB.gen(usage: PB.usage(input: 7), lastStep: 3, model: "gemini-flash")
            .withUnsafeBytes { ProtoScan.genData($0) }
        XCTAssertEqual(fallback?.model, "gemini-flash")
        XCTAssertEqual(fallback?.step, 4)
    }

    #if canImport(SQLite3)
    func testCodexUsesOneWeightPerActiveThreadAndNeverReadsText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state_5.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        let now = Date(timeIntervalSince1970: 1_795_531_200)
        let stamp = Int(now.timeIntervalSince1970) - 3600
        let sql = """
        CREATE TABLE threads (model TEXT, tokens_used INTEGER, updated_at INTEGER);
        INSERT INTO threads VALUES ('sol', 10000000, \(stamp)), ('luna', 20, \(stamp)),
            (NULL, 99, \(stamp)), ('empty', 0, \(stamp)), ('old', 50, \(stamp - 10000)),
            ('future', 50, \(stamp + 10000));
        """
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        let cal = TokenSeries.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let data = CodexModelActivity.read(db: path, since: now.addingTimeInterval(-7_200), now: now, calendar: cal)
        XCTAssertEqual(data?.values.first, ["sol": 1, "luna": 1, ModelDistribution.unknown: 1])
        XCTAssertNil(CodexModelActivity.read(db: dir.appendingPathComponent("missing.sqlite"), since: now, now: now, calendar: cal))
    }
    #endif
}

#if canImport(SQLite3)
final class GeminiModelDistributionDBTests: GeminiDBTestCase {
    func testUsesGenerationsForDistributionButKeepsStepBasedTotalsAndCachesBoth() {
        let id = Data(repeating: 4, count: 16)
        let gen = PB.bytes(1, PB.bytes(4, PB.usage(input: 8)) + PB.str(21, "Gemini Pro")
                          + PB.bytes(9, PB.ts(4, d1))) + PB.bytes(4, id)
        let other = PB.bytes(1, PB.bytes(4, PB.usage(input: 12)) + PB.bytes(9, PB.ts(4, d1)))
        makeDB("antigravity", "m", steps: [step(100, at: d1)], gens: [gen, gen, other])
        let url = GeminiUsageCacheFile.url(home: home)
        let a = GeminiHistoryScanner(home: home, cacheURL: url, calendar: utc).scan()
        XCTAssertEqual(a.daily["2026-11-18"], 100)
        XCTAssertEqual(a.modelDaily?["2026-11-18"], ["Gemini Pro": 8, "未知模型": 12])
        let b = GeminiHistoryScanner(home: home, cacheURL: url, calendar: utc)
        XCTAssertEqual(b.loadDiskCache()?.modelDaily, a.modelDaily)
        XCTAssertEqual(b.scan().modelDaily, a.modelDaily)
        XCTAssertEqual(b.openCount, 0)
    }
}
#endif
