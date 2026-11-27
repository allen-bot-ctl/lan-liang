/// 面板里按 Esc 由里往外一层一层退（契约 0.3.15）：设置页回主页，主页收起面板。
/// 只认不带修饰键的 Esc（keyCode 53）；⌘ / ⌥ / ⌃ / ⇧ 加 Esc 或别的键（如 ⌘. 触发的 cancelOperation）不处理。
public enum PanelEscape {
    public enum Action: Equatable { case returnToMain, closePanel, ignore }

    public struct Modifiers: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public static let escapeKeyCode: UInt16 = 53

    public static func action(keyCode: UInt16?, modifiers: Modifiers, showsSettings: Bool) -> Action {
        guard keyCode == escapeKeyCode, modifiers.isEmpty else { return .ignore }
        return showsSettings ? .returnToMain : .closePanel
    }
}
