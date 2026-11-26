import AppKit

/// NSResponder receiver kept alive by the app delegate; NSTrackingArea does not retain its owner.
final class HoverTracking: NSResponder {
    var didEnter: (() -> Void)?
    var didLeave: (() -> Void)?

    func attach(to view: NSView) {
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { didEnter?() }
    override func mouseExited(with event: NSEvent) { didLeave?() }
}
