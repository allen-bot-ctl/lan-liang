import XCTest
@testable import LanLiangCore

final class GeminiHistoryWorkGateTests: XCTestCase {
    func testDebouncesAndCoalescesForegroundAndManualBursts() {
        var gate = GeminiHistoryWorkGate()
        XCTAssertTrue(gate.request(now: 10))
        XCTAssertFalse(gate.request(now: 10.02, manual: true))
        XCTAssertTrue(gate.start(now: 10.26, visible: true))
        XCTAssertTrue(gate.inFlight)
        XCTAssertFalse(gate.request(now: 11, manual: true))
        gate.finish()
        XCTAssertFalse(gate.request(now: 12, manual: true))
        XCTAssertFalse(gate.request(now: 20))
        XCTAssertTrue(gate.request(now: 20, manual: true))
        XCTAssertTrue(gate.start(now: 20.26, visible: true))
        gate.finish()
        XCTAssertTrue(gate.request(now: 66))
    }

    func testNoQueuedWorkStartsWithoutVisibleHistory() {
        var gate = GeminiHistoryWorkGate()
        XCTAssertFalse(gate.start(now: 10, visible: true))
        XCTAssertTrue(gate.request(now: 11))
        XCTAssertFalse(gate.start(now: 11.26, visible: false))
        XCTAssertTrue(gate.request(now: 12))
        gate.cancelPending()
        XCTAssertFalse(gate.start(now: 12.5, visible: true))
        XCTAssertTrue(gate.request(now: 13))
        XCTAssertTrue(gate.start(now: 13.26, visible: true))
    }
}
