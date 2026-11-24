import Foundation

/// 额度窗口的种类：只按窗口长度认，不按接口里的位置认。
public enum WindowKind: String, Codable, Equatable {
    case fiveHour, weekly, other

    public static func from(windowSeconds: Int) -> WindowKind {
        switch windowSeconds {
        case 18_000: return .fiveHour
        case 604_800: return .weekly
        default: return .other
        }
    }
}

/// 一个额度窗口：剩余百分比（0…100）与重置时间。
public struct QuotaWindow: Codable, Equatable {
    public var kind: WindowKind
    public var remainingPercent: Double
    public var resetsAt: Date?

    public init(kind: WindowKind, remainingPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

/// 服务在菜单栏与面板上的状态（对应契约 §3 状态表）。
public enum ServiceState: Equatable {
    case notLoggedIn
    case apiKeyOnly
    case loading
    case ok(weekly: QuotaWindow?, fiveHour: QuotaWindow?)
    case fetchFailed
    case loginExpired
    case keychainDenied
}

public enum Service: String, CaseIterable, Codable {
    case codex, gemini
}

/// 菜单栏一组的文字：nil 表示整组不显示。
public struct MenuBarGroup: Equatable {
    public var service: Service
    public var primary: String
    public var secondary: String?
}

public enum MenuBarText {
    public static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    public static func group(for service: Service, state: ServiceState) -> MenuBarGroup? {
        switch state {
        case .notLoggedIn, .apiKeyOnly:
            return nil
        case .loading, .fetchFailed, .loginExpired, .keychainDenied:
            return MenuBarGroup(service: service, primary: "--", secondary: nil)
        case let .ok(weekly, fiveHour):
            guard let w = weekly else {
                if let f = fiveHour { return MenuBarGroup(service: service, primary: percent(f.remainingPercent), secondary: nil) }
                return MenuBarGroup(service: service, primary: "--", secondary: nil)
            }
            return MenuBarGroup(service: service, primary: percent(w.remainingPercent),
                                secondary: fiveHour.map { percent($0.remainingPercent) })
        }
    }
}
