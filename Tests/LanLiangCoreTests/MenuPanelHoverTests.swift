import XCTest
@testable import LanLiangCore

final class MenuPanelHoverTests: XCTestCase {
    func testGapThenEnterPanelAndLeave() {
        var hover = MenuPanelHover()
        hover.enterItem()
        XCTAssertEqual(hover.mode, .preview)
        hover.leave(now: 1)
        hover.tick(now: 1.2, pointerInside: false)
        XCTAssertEqual(hover.mode, .preview)
        hover.enterPanel()
        hover.tick(now: 2, pointerInside: false)
        XCTAssertEqual(hover.mode, .preview)
        hover.leave(now: 2)
        hover.tick(now: 2.31, pointerInside: false)
        XCTAssertEqual(hover.mode, .hidden)
    }

    func testReorderedExitCannotDismissWhenPointerStillOverEitherRegion() {
        var hover = MenuPanelHover()
        hover.enterItem()
        hover.enterPanel()
        hover.leave(now: 1)
        hover.tick(now: 1.31, pointerInside: true)
        XCTAssertEqual(hover.mode, .preview)
        XCTAssertNil(hover.deadline)
    }

    func testFirstClickPinsAndSecondClickDismisses() {
        var hover = MenuPanelHover()
        hover.enterItem()
        hover.leave(now: 1)
        hover.click()
        XCTAssertEqual(hover.mode, .pinned)
        hover.leave(now: 2)
        hover.tick(now: 3, pointerInside: false)
        XCTAssertEqual(hover.mode, .pinned)
        hover.click()
        XCTAssertEqual(hover.mode, .hidden)
        hover.click()
        XCTAssertEqual(hover.mode, .pinned)
    }

    func testRightClickSuppressesHoverAndDoesNotOpenOnMenuEnd() {
        var hover = MenuPanelHover()
        hover.enterItem()
        hover.leave(now: 1)
        hover.beginMenu()
        hover.enterItem()
        hover.click()
        hover.tick(now: 2, pointerInside: false)
        XCTAssertEqual(hover.mode, .hidden)
        hover.endMenu()
        XCTAssertEqual(hover.mode, .hidden)
        hover.enterItem()
        XCTAssertEqual(hover.mode, .preview)
        hover.pin()
        hover.leave(now: 3)
        XCTAssertNil(hover.deadline)
    }
}
