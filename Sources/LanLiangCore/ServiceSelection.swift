import Foundation

/// 监听服务（契约 0.3.0 §1）：Codex、Gemini 各自开关，至少保留一个。
public struct ServiceSelection: Equatable {
    public var codex: Bool
    public var gemini: Bool

    public static let codexKey = "monitor.codex"
    public static let geminiKey = "monitor.gemini"
    public static let all = ServiceSelection(codex: true, gemini: true)

    public init(codex: Bool = true, gemini: Bool = true) {
        self.codex = codex
        self.gemini = gemini
        // 不允许两个都关：都关时按两个都开处理。
        if !codex && !gemini { self.codex = true; self.gemini = true }
    }

    public func isOn(_ s: Service) -> Bool { s == .codex ? codex : gemini }

    /// 开着的服务，固定顺序：Codex 在上、Gemini 在下。
    public var enabled: [Service] { Service.allCases.filter { isOn($0) } }

    /// 只开了一个服务（菜单栏和面板用放大的「仅一个」状态）。
    public var isSingle: Bool { enabled.count == 1 }

    /// 这个开关能不能拨：最后一个开着的服务不能关。
    public func canToggle(_ s: Service) -> Bool { !isOn(s) || enabled.count > 1 }

    /// 拨开关后的结果；会让两个都关时原样返回（偏好不变）。
    public func setting(_ s: Service, on: Bool) -> ServiceSelection {
        var c = codex, g = gemini
        if s == .codex { c = on } else { g = on }
        guard c || g else { return self }
        return ServiceSelection(codex: c, gemini: g)
    }

    /// 读偏好：没写过的键按 true（升级用户保持两个都开）。
    public static func load(from d: UserDefaults) -> ServiceSelection {
        let c = d.object(forKey: codexKey) == nil ? true : d.bool(forKey: codexKey)
        let g = d.object(forKey: geminiKey) == nil ? true : d.bool(forKey: geminiKey)
        return ServiceSelection(codex: c, gemini: g)
    }

    public func save(to d: UserDefaults) {
        d.set(codex, forKey: Self.codexKey)
        d.set(gemini, forKey: Self.geminiKey)
    }

    /// 截图用 --debug-services=codex|gemini|codex,gemini；认不出来返回 nil。
    public static func parse(_ text: String) -> ServiceSelection? {
        let parts = Set(text.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let c = parts.contains("codex"), g = parts.contains("gemini")
        guard c || g else { return nil }
        return ServiceSelection(codex: c, gemini: g)
    }

    /// 打印用：「codex,gemini」。
    public var debugText: String { enabled.map { $0.rawValue }.joined(separator: ",") }
}

/// 消耗汇总（契约 0.3.0 §4）：开着的服务各自全部日合计相加；只用面板已经拿到的数据。
public struct UsageSummary: Equatable {
    public enum ItemState: Equatable {
        case loading
        /// 拿不到（Codex 官方接口失败 / Gemini 全部读取失败）。
        case unavailable
        case value(Int64)
    }

    public struct Item: Equatable {
        public var service: Service
        public var state: ItemState
        /// 占比 0…1；不画占比条时为 nil。
        public var share: Double?

        public var tokens: Int64? {
            if case let .value(v) = state { return v }
            return nil
        }
    }

    public var items: [Item]
    /// 还有开着的服务没拿到数据：显示「正在统计…」，不显示 0。
    public var loading: Bool
    /// 有开着的服务拿不到：「累计」后面标「不完整」。
    public var incomplete: Bool
    /// 能拿到的服务合计；一个都拿不到时为 nil（显示「—」）。
    public var total: Int64?

    /// 两个都开、都拿到、合计大于 0 时才画占比条和百分比。
    public var showsSplit: Bool { items.count >= 2 && !loading && !incomplete && (total ?? 0) > 0 }

    public static func sum(_ d: [String: Int64]) -> Int64 { d.values.reduce(0, +) }

    public static func make(selection: ServiceSelection, official: [String: Int64]?, officialLoaded: Bool,
                            gemini: GeminiHistory?) -> UsageSummary {
        var items: [Item] = []
        for s in selection.enabled {
            let st: ItemState
            if s == .codex {
                if !officialLoaded { st = .loading } else if let o = official { st = .value(sum(o)) } else { st = .unavailable }
            } else {
                if let h = gemini { st = h.display == .allFailed ? .unavailable : .value(sum(h.daily)) } else { st = .loading }
            }
            items.append(Item(service: s, state: st, share: nil))
        }
        let loading = items.contains { $0.state == .loading }
        let incomplete = items.contains { $0.state == .unavailable }
        let values = items.compactMap { $0.tokens }
        let total: Int64? = (loading || values.isEmpty) ? nil : values.reduce(0, +)
        var r = UsageSummary(items: items, loading: loading, incomplete: incomplete, total: total)
        if r.showsSplit, let t = total {
            for i in r.items.indices {
                r.items[i].share = Double(r.items[i].tokens ?? 0) / Double(t)
            }
        }
        return r
    }

    /// 百分比保留一位小数：「97.6%」。
    public static func percent(_ share: Double) -> String { String(format: "%.1f%%", share * 100) }
}

/// 设置窗口文案（契约 0.3.0 §3、§4）。
public enum SettingsText {
    public static let keepOneHint = "至少保留一个服务，最后一个开关不能关。"

    /// 监听服务一行下面的小字：「已登录 · 套餐 · 掩码邮箱」或「未检测到登录」。
    /// 关掉的服务不请求，从没拿到过账号信息时写「已关闭」。
    public static func accountLine(service: Service, snap: ServiceSnapshot, isOn: Bool = true) -> String {
        if !isOn, snap.status == .loading, snap.plan == nil, snap.email == nil { return "已关闭" }
        switch snap.status {
        case .notLoggedIn:
            return "未检测到登录"
        case .keychainUnavailable, .keychainDenied, .apiKeyOnly:
            return snap.message(for: service) ?? "未检测到登录"
        case .loading where snap.plan == nil && snap.email == nil:
            return "正在读取…"
        default:
            let parts: [String?] = ["已登录", snap.plan, snap.email.map { Fmt.maskEmail($0) }]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// 汇总里拿不到的那一项的说明。
    public static func unavailable(_ s: Service) -> String {
        s == .codex ? "官方用量暂时拿不到" : "本机记录读取失败"
    }
}
