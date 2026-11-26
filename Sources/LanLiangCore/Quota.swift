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

/// 进度条颜色档（契约 d73e843）：剩余 ≥20% 正常（systemGreen），<20% 告急（systemRed），没有中间档。
public enum QuotaLevel: String, Equatable {
    case normal, critical

    public static func of(remainingPercent p: Double) -> QuotaLevel { p < 20 ? .critical : .normal }
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

public enum Service: String, CaseIterable, Codable {
    case codex, gemini

    public var title: String { self == .codex ? "Codex" : "Gemini" }
}

/// 服务状态（契约 §4 状态表）。
public enum ServiceStatus: String, Codable, Equatable {
    case ok, loading, fetchFailed, loginExpired, apiKeyOnly, notLoggedIn, keychainUnavailable, keychainDenied
}

/// 一个服务当前的全部数据；额度保留上次成功值。
public struct ServiceSnapshot: Codable, Equatable {
    public var status: ServiceStatus
    public var email: String?
    public var plan: String?
    public var subscriptionUntil: Date?
    /// 套餐原始值（Codex：实时 plan_type 优先，否则 id_token）；判断付费档用。
    public var planRaw: String?
    /// planRaw 是否来自实时 wham/usage。
    public var planIsLive: Bool?
    public var weekly: QuotaWindow?
    public var fiveHour: QuotaWindow?
    /// 上次成功获取额度的时间，而不是最近一次刷新尝试的时间。
    public var quotaUpdatedAt: Date?

    public init(status: ServiceStatus, email: String? = nil, plan: String? = nil, subscriptionUntil: Date? = nil,
                weekly: QuotaWindow? = nil, fiveHour: QuotaWindow? = nil,
                planRaw: String? = nil, planIsLive: Bool? = nil, quotaUpdatedAt: Date? = nil) {
        self.status = status; self.email = email; self.plan = plan
        self.planRaw = planRaw; self.planIsLive = planIsLive
        self.subscriptionUntil = subscriptionUntil; self.weekly = weekly; self.fiveHour = fiveHour
        self.quotaUpdatedAt = quotaUpdatedAt
    }

    public var hasQuota: Bool { weekly != nil || fiveHour != nil }

    /// Gemini 暂时拿不到新额度时，旧值仅供参考。
    public var hasStaleQuota: Bool {
        hasQuota && [.fetchFailed, .loginExpired, .keychainUnavailable, .keychainDenied].contains(status)
    }

    /// 面板额度区的提示文字（红字或灰字）；nil 表示不显示提示。
    public func message(for service: Service) -> String? {
        switch status {
        case .ok: return nil
        case .loading: return hasQuota ? nil : "正在读取…"
        case .fetchFailed:
            return service == .gemini ? "Gemini 额度获取失败，可重新读取登录后再试"
                                      : "额度获取失败，5 分钟后自动重试"
        case .loginExpired:
            return service == .codex ? "Codex 登录已过期，在终端运行一次 codex 重新登录"
                                     : "Gemini 登录已过期，请在 Antigravity 登录后重新读取"
        case .apiKeyOnly: return "API Key 账号没有订阅额度"
        case .notLoggedIn:
            return service == .gemini ? "未检测到 Antigravity 登录" : "未检测到登录"
        case .keychainUnavailable: return "暂时无法在后台读取 Gemini 登录，栏量会自动重试"
        case .keychainDenied: return "需要钥匙串授权才能重新读取 Gemini 登录"
        }
    }
}

/// 菜单栏一行的文字：nil 表示这一行不显示。
public struct MenuBarGroup: Equatable {
    public var service: Service
    public var primary: String
    public var secondary: String?
}

public enum MenuBarText {
    public static let staleMark = "*"
    public static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    /// 5 小时剩余：只写数字，不带 %（契约 0.1.2 §2）。
    public static func number(_ v: Double) -> String { "\(Int(v.rounded()))" }

    /// 菜单栏要显示的行：上 Codex 下 Gemini；空数组 = 只显示栏量图标。
    public static func rows(codex: ServiceSnapshot, gemini: ServiceSnapshot) -> [MenuBarGroup] {
        rows(codex: codex, gemini: gemini, selection: .all)
    }

    /// 只显示开着的服务（契约 0.3.0 §1）：关掉的那一行不显示。
    public static func rows(codex: ServiceSnapshot, gemini: ServiceSnapshot, selection: ServiceSelection) -> [MenuBarGroup] {
        [selection.codex ? group(for: .codex, snapshot: codex) : nil,
         selection.gemini ? group(for: .gemini, snapshot: gemini) : nil].compactMap { $0 }
    }

    public static func group(for service: Service, snapshot s: ServiceSnapshot) -> MenuBarGroup? {
        if service == .gemini && s.hasStaleQuota {
            // 菜单栏无空间显示说明；两列旧值都加星，面板写明「上次额度（非实时）」。
            if let weekly = s.weekly {
                return MenuBarGroup(service: service, primary: percent(weekly.remainingPercent) + staleMark,
                                    secondary: s.fiveHour.map { number($0.remainingPercent) + staleMark })
            }
            if let fiveHour = s.fiveHour {
                return MenuBarGroup(service: service, primary: percent(fiveHour.remainingPercent) + staleMark, secondary: nil)
            }
        }
        switch s.status {
        case .notLoggedIn, .apiKeyOnly, .keychainDenied:
            return nil
        case .loginExpired, .keychainUnavailable:
            return MenuBarGroup(service: service, primary: "--", secondary: nil)
        case .ok, .loading, .fetchFailed:
            guard s.hasQuota else {
                return MenuBarGroup(service: service, primary: s.status == .loading ? "…" : "--", secondary: nil)
            }
            if let w = s.weekly {
                return MenuBarGroup(service: service, primary: percent(w.remainingPercent),
                                    secondary: s.fiveHour.map { number($0.remainingPercent) })
            }
            return MenuBarGroup(service: service, primary: percent(s.fiveHour!.remainingPercent), secondary: nil)
        }
    }
}
