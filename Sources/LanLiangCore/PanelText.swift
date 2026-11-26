import Foundation

/// 面板顶栏、页签用到的纯文案（契约 0.2.0 §3、§4）。
public enum PanelText {
    /// 「刚刚」「x 分钟前」「x 小时前」；last 为 nil 返回 nil。
    public static func ago(last: Date?, now: Date) -> String? {
        guard let last = last else { return nil }
        let s = max(0, Int(now.timeIntervalSince(last)))
        if s < 60 { return "刚刚" }
        if s < 3_600 { return "\(s / 60) 分钟前" }
        return "\(s / 3_600) 小时前"
    }

    /// 顶栏「x 分钟前更新」；刷新中为「正在刷新…」；还没刷新过为空。
    public static func updated(last: Date?, now: Date, refreshing: Bool) -> String {
        if refreshing { return "正在刷新…" }
        return ago(last: last, now: now).map { $0 + "更新" } ?? ""
    }

    /// 页签用的额度：有周剩余取周，只有 5 小时取 5 小时；没登录或没有额度为 nil。
    public static func tabWindow(_ s: ServiceSnapshot, service: Service? = nil) -> QuotaWindow? {
        if service == .gemini && s.hasStaleQuota { return s.weekly ?? s.fiveHour }
        switch s.status {
        case .notLoggedIn, .apiKeyOnly, .keychainDenied: return nil
        default: return s.weekly ?? s.fiveHour
        }
    }

    /// 页签靠右的百分比；没有额度为「—」。
    public static func tabPercent(_ s: ServiceSnapshot, service: Service? = nil) -> String {
        let suffix = service == .gemini && s.hasStaleQuota ? MenuBarText.staleMark : ""
        return tabWindow(s, service: service).map { MenuBarText.percent($0.remainingPercent) + suffix } ?? "—"
    }
}

/// 诊断开关 --debug-gemini-scan-timing 的两段计时（契约 0.1.5、0.2.0 §8.2）。
public enum GeminiScanTiming {
    public struct Result {
        public var first: GeminiHistoryScanner.Timings
        public var conversations: Int
        public var failed: Int
        public var firstOpened: Int
        public var cacheWritten: Bool
        public var load: Double
        public var rescan: Double
        public var cachedOpened: Int
    }

    /// 临时缓存放在独立子目录里，结束时整个删掉；只影响诊断，不碰正式缓存。
    public static func run(home: URL, tempRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
                           calendar: @escaping () -> Calendar = { TokenSeries.calendar() }) -> Result {
        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent("lanliang-timing-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("gemini-usage-cache.json")
        let s1 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: calendar)
        let r = s1.scan()
        let written = fm.fileExists(atPath: cacheURL.path)
        let s2 = GeminiHistoryScanner(home: home, cacheURL: cacheURL, calendar: calendar)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = s2.loadDiskCache()
        let load = CFAbsoluteTimeGetCurrent() - t0
        _ = s2.scan()
        return Result(first: s1.lastTimings, conversations: r.conversations, failed: r.failed, firstOpened: s1.openCount,
                      cacheWritten: written, load: load, rescan: s2.lastTimings.total, cachedOpened: s2.openCount)
    }

    public static func lines(_ x: Result) -> [String] {
        let t = x.first
        return [
            String(format: "GEMINI_SCAN_TIMING first: total=%.3fs copy=%.3fs sqlite=%.3fs decode=%.3fs dbs=%d failed=%d opened=%d",
                   t.total, t.copy, t.sqlite, t.decode, x.conversations, x.failed, x.firstOpened) + " cacheWritten=" + (x.cacheWritten ? "yes" : "no"),
            String(format: "GEMINI_SCAN_TIMING cached: load=%.4fs rescan=%.4fs opened=%d", x.load, x.rescan, x.cachedOpened),
        ]
    }
}
