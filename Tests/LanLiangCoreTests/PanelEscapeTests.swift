import XCTest
@testable import LanLiangCore

final class PanelEscapeTests: XCTestCase {
    func testSettingsPageReturnsToMain() {
        XCTAssertEqual(PanelEscape.action(keyCode: 53, modifiers: [], showsSettings: true), .returnToMain)
    }

    func testMainPageClosesPanel() {
        XCTAssertEqual(PanelEscape.action(keyCode: 53, modifiers: [], showsSettings: false), .closePanel)
    }

    func testModifiersAreIgnored() {
        for m: PanelEscape.Modifiers in [.command, .option, .control, .shift, [.command, .shift]] {
            XCTAssertEqual(PanelEscape.action(keyCode: 53, modifiers: m, showsSettings: true), .ignore)
            XCTAssertEqual(PanelEscape.action(keyCode: 53, modifiers: m, showsSettings: false), .ignore)
        }
    }

    func testOtherKeysAreIgnored() {
        // ⌘. 也会走 cancelOperation：keyCode 47，不是 Esc。
        XCTAssertEqual(PanelEscape.action(keyCode: 47, modifiers: [], showsSettings: false), .ignore)
        XCTAssertEqual(PanelEscape.action(keyCode: nil, modifiers: [], showsSettings: true), .ignore)
    }
}
