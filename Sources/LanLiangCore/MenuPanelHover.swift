import Foundation

/// Lifecycle for a menu-bar preview. Time is monotonic and injected at each transition.
struct MenuPanelHover {
    enum Mode: Equatable { case hidden, preview, pinned }
    static let grace: TimeInterval = 0.30
    private(set) var mode: Mode = .hidden
    private(set) var deadline: TimeInterval?
    private(set) var menuOpen = false

    mutating func enterItem() {
        guard !menuOpen else { return }
        deadline = nil
        if mode == .hidden { mode = .preview }
    }

    mutating func enterPanel() { deadline = nil }

    mutating func leave(now: TimeInterval) {
        guard mode == .preview, !menuOpen else { return }
        deadline = now + Self.grace
    }

    mutating func tick(now: TimeInterval, pointerInside: Bool) {
        guard let deadline, now >= deadline else { return }
        self.deadline = nil
        if !pointerInside, mode == .preview { hide() }
    }

    mutating func click() {
        guard !menuOpen else { return }
        if mode == .pinned { hide() } else { pin() }
    }

    mutating func pin() {
        mode = .pinned
        deadline = nil
    }

    mutating func hide() {
        mode = .hidden
        deadline = nil
    }

    mutating func beginMenu() {
        menuOpen = true
        hide()
    }

    mutating func endMenu() { menuOpen = false }
}
