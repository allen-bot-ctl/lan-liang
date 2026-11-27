import Foundation

// 0.4.0 AI 会话状态（契约 docs/changes/0.4.0.md）。纯逻辑：解析状态行、单会话状态机、读文件游标、归并。
// 只取事件类型、call_id 和时间；不保存、不打印任何行内容，内存里不存文件路径（会话用相对路径的哈希做键）。

public enum AgentTool: String, CaseIterable, Sendable {
    case codex, antigravity
    public var title: String { self == .codex ? "Codex" : "Antigravity" }
}

/// 优先级：问你问题 > 工作中 > 已中断/出错 > 刚完成 > 空闲（契约 §1.5）。
public enum AgentPhase: Int, Comparable, Sendable, CaseIterable {
    case idle = 0, done = 1, failed = 2, working = 3, asking = 4
    public static func < (a: AgentPhase, b: AgentPhase) -> Bool { a.rawValue < b.rawValue }
    public var debugName: String {
        switch self {
        case .idle: return "idle"
        case .done: return "done"
        case .failed: return "failed"
        case .working: return "working"
        case .asking: return "asking"
        }
    }
}

public struct AgentToolStatus: Equatable, Sendable {
    public var phase: AgentPhase
    /// 工作中 / 问你问题：最早开始的会话的开始时间。
    public var since: Date?
    public init(phase: AgentPhase, since: Date? = nil) { self.phase = phase; self.since = since }
    public static let idle = AgentToolStatus(phase: .idle)
}

/// 两个工具的状态；nil = 这个服务在设置里关掉了（不监听、不显示）。
public struct AgentSnapshot: Equatable, Sendable {
    public var codex: AgentToolStatus?
    public var antigravity: AgentToolStatus?
    public init(codex: AgentToolStatus? = nil, antigravity: AgentToolStatus? = nil) {
        self.codex = codex; self.antigravity = antigravity
    }
    public func status(_ t: AgentTool) -> AgentToolStatus? { t == .codex ? codex : antigravity }
    /// 菜单栏小点：两个工具里优先级最高的；空闲 = 不画点。
    public var dot: AgentPhase { [codex?.phase ?? .idle, antigravity?.phase ?? .idle].max() ?? .idle }
    public var isShown: Bool { codex != nil || antigravity != nil }
    public var debugText: String {
        AgentTool.allCases.compactMap { t in status(t).map { "\(t.rawValue):\($0.phase.debugName)" } }.joined(separator: ",")
    }

    /// 截图用：「codex:working:12,antigravity:done」，第三段是已经工作了几分钟。
    public static func parseDebug(_ text: String, now: Date) -> AgentSnapshot {
        var s = AgentSnapshot()
        for part in text.split(separator: ",") {
            let f = part.split(separator: ":").map(String.init)
            guard f.count >= 2, let tool = AgentTool(rawValue: f[0]) else { continue }
            let phase: AgentPhase
            switch f[1] {
            case "working": phase = .working
            case "asking": phase = .asking
            case "done": phase = .done
            case "aborted", "error", "failed": phase = .failed
            default: phase = .idle
            }
            let minutes = f.count >= 3 ? Double(f[2]) ?? 0 : 0
            let st = AgentToolStatus(phase: phase, since: phase >= .working ? now.addingTimeInterval(-minutes * 60) : nil)
            if tool == .codex { s.codex = st } else { s.antigravity = st }
        }
        return s
    }
}

/// 面板「会话」一栏的唯一写法（契约 §3）。
public enum AgentStatusText {
    public static func text(_ s: AgentToolStatus, tool: AgentTool, now: Date) -> String {
        switch s.phase {
        case .working:
            let m = s.since.map { Int(max(0, now.timeIntervalSince($0)) / 60) } ?? 0
            if m < 1 { return "工作中" }
            if m < 60 { return "工作中 · \(m) 分钟" }
            return "工作中 · 1 小时以上"
        case .asking: return "问你问题"
        case .done: return "刚完成"
        case .failed: return tool == .codex ? "已中断" : "出错"
        case .idle: return "空闲"
        }
    }
}

/// 小点颜色（契约 §2，浅色 / 深色菜单栏的系统色固定值）。单独放这里，改色只改这一处。
public enum AgentDotStyle {
    public static let diameter: Double = 6
    public static let gap: Double = 4
    /// 有点时状态项变宽 10pt；空闲不占位。
    public static var extraWidth: Double { gap + diameter }
    /// 工作中慢闪的暗帧不透明度。
    public static let dimAlpha: Double = 0.35
    public static let blinkInterval: TimeInterval = 1

    public static func rgb(_ p: AgentPhase, dark: Bool) -> (r: Int, g: Int, b: Int)? {
        switch p {
        case .working: return dark ? (0x0A, 0x84, 0xFF) : (0x00, 0x7A, 0xFF)
        case .asking: return dark ? (0xFF, 0x9F, 0x0A) : (0xFF, 0x95, 0x00)
        case .done: return dark ? (0x30, 0xD1, 0x58) : (0x34, 0xC7, 0x59)
        case .failed: return dark ? (0xFF, 0x45, 0x3A) : (0xFF, 0x3B, 0x30)
        case .idle: return nil
        }
    }
    public static func blinks(_ p: AgentPhase) -> Bool { p == .working }
}

// MARK: 解析

public enum AgentEvent: Equatable, Sendable {
    case taskStarted, taskComplete, turnAborted
    case askStart(callID: String), askOutput(callID: String)
    case running, done, error

    public var debugName: String {
        switch self {
        case .taskStarted: return "task_started"
        case .taskComplete: return "task_complete"
        case .turnAborted: return "turn_aborted"
        case .askStart: return "ask_start"
        case .askOutput: return "ask_output"
        case .running: return "RUNNING"
        case .done: return "DONE"
        case .error: return "ERROR"
        }
    }
}

public enum AgentLineParser {
    /// 单行上限：超过就不做 JSON 解析（契约 §1.3）。
    public static let maxLineBytes = 64 * 1024
    /// 长行例外：有未结束的提问时只看前 1KB。
    public static let longLinePeek = 1024
    static let askNames: Set<String> = ["request_user_input_async", "request_user_input"]
    private static let kEventMsg = Data("\"event_msg\"".utf8)
    private static let kFunctionCall = Data("\"function_call\"".utf8)
    private static let kFunctionCallOutput = Data("\"function_call_output\"".utf8)
    private static let kStatus = Data("\"status\"".utf8)

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    /// Codex rollout 一行（不含换行）。pending = 当前会话记下的提问 call_id。
    public static func codex<D: DataProtocol>(_ raw: D, pending: Set<String>) -> (event: AgentEvent, time: Date?)? {
        let line = Data(raw)
        if line.count > maxLineBytes { return codexLong(line, pending: pending) }
        let isEvent = line.range(of: kEventMsg) != nil
        let isCall = line.range(of: kFunctionCall) != nil
        let isOutput = !pending.isEmpty && line.range(of: kFunctionCallOutput) != nil
        guard isEvent || isCall || isOutput else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any],
              let ptype = payload["type"] as? String else { return nil }
        let time = date(obj["timestamp"])
        switch type {
        case "event_msg":
            switch ptype {
            case "task_started": return (.taskStarted, time)
            case "task_complete": return (.taskComplete, time)
            case "turn_aborted": return (.turnAborted, time)
            default: return nil
            }
        case "response_item":
            guard let id = payload["call_id"] as? String, !id.isEmpty else { return nil }
            if ptype == "function_call", let name = payload["name"] as? String, askNames.contains(name) {
                return (.askStart(callID: id), time)
            }
            if ptype == "function_call_output", pending.contains(id) { return (.askOutput(callID: id), time) }
            return nil
        default:
            return nil
        }
    }

    /// 超过 64KB 的行：只有未结束的提问时看前 1KB，同时含 "function_call_output" 和记下的某个 call_id 才算输出。
    static func codexLong(_ line: Data, pending: Set<String>) -> (event: AgentEvent, time: Date?)? {
        guard !pending.isEmpty else { return nil }
        let head = line.prefix(longLinePeek)
        guard head.range(of: kFunctionCallOutput) != nil else { return nil }
        for id in pending.sorted() where head.range(of: Data("\"\(id)\"".utf8)) != nil {
            return (.askOutput(callID: id), nil)
        }
        return nil
    }

    /// Antigravity transcript.jsonl 一行：只取顶层 status。
    public static func antigravity<D: DataProtocol>(_ raw: D) -> AgentEvent? {
        let line = Data(raw)
        guard line.count <= maxLineBytes, line.range(of: kStatus) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let status = obj["status"] as? String else { return nil }
        switch status {
        case "RUNNING": return .running
        case "DONE": return .done
        case "ERROR": return .error
        default: return nil
        }
    }
}

// MARK: 单会话状态机

public struct AgentSession: Equatable, Sendable {
    public static let workingTimeout: TimeInterval = 10 * 60
    public static let askingTimeout: TimeInterval = 30 * 60
    public static let fadeAfter: TimeInterval = 60
    public static let doneDebounce: TimeInterval = 5

    public private(set) var phase: AgentPhase = .idle
    public private(set) var since: Date?
    var askedAt: Date?
    var phaseAt: Date?
    var lastLineAt: Date?
    var doneCandidateAt: Date?
    public private(set) var pending: Set<String> = []

    public init() {}

    /// 文件追加了任何一行（不必认识）：工作中重新按 10 分钟计时。
    public mutating func noteLine(at now: Date) { lastLineAt = now }

    public mutating func apply(_ e: AgentEvent, at now: Date) {
        switch e {
        case .taskStarted, .running:
            pending = []
            doneCandidateAt = nil
            if !(phase == .working || phase == .asking) || since == nil { since = now }
            phase = .working
            lastLineAt = max(lastLineAt ?? now, now)
        case .taskComplete:
            finish(.done, at: now)
        case .turnAborted, .error:
            finish(.failed, at: now)
        case .askStart(let id):
            pending.insert(id)
            if since == nil || !(phase == .working || phase == .asking) { since = now }
            phase = .asking
            askedAt = now
            doneCandidateAt = nil
        case .askOutput(let id):
            guard pending.remove(id) != nil else { return }
            if pending.isEmpty, phase == .asking {
                phase = .working
                lastLineAt = max(lastLineAt ?? now, now)
            }
        case .done:
            if phase == .working { doneCandidateAt = now } else { finish(.done, at: now) }
        }
    }

    private mutating func finish(_ p: AgentPhase, at now: Date) {
        pending = []
        doneCandidateAt = nil
        askedAt = nil
        since = nil
        phase = p
        phaseAt = now
    }

    private mutating func toIdle() {
        pending = []; doneCandidateAt = nil; askedAt = nil; since = nil; phaseAt = nil; phase = .idle
    }

    /// 处理到点：DONE 去抖、10 分钟、30 分钟兜底、60 秒淡出。
    public mutating func advance(to now: Date) {
        if let c = doneCandidateAt, now >= c + Self.doneDebounce {
            finish(.done, at: c + Self.doneDebounce)
        }
        switch phase {
        case .working:
            if doneCandidateAt == nil, let l = lastLineAt, now >= l + Self.workingTimeout { toIdle() }
        case .asking:
            if let a = askedAt, now >= a + Self.askingTimeout { toIdle() }
        case .done, .failed:
            if let p = phaseAt, now >= p + Self.fadeAfter { toIdle() }
        case .idle:
            break
        }
    }

    public var deadline: Date? {
        if let c = doneCandidateAt { return c + Self.doneDebounce }
        switch phase {
        case .working: return lastLineAt.map { $0 + Self.workingTimeout }
        case .asking: return askedAt.map { $0 + Self.askingTimeout }
        case .done, .failed: return phaseAt.map { $0 + Self.fadeAfter }
        case .idle: return nil
        }
    }

    /// 启动恢复（契约 §1.3）：只留工作中（mtime 10 分钟内）和未结束的提问（提问 30 分钟内）。
    mutating func keepOnlyRestorable(mtime: Date, now: Date) {
        switch phase {
        case .working where doneCandidateAt == nil && now.timeIntervalSince(mtime) <= Self.workingTimeout:
            lastLineAt = mtime
        case .asking where (askedAt.map({ now.timeIntervalSince($0) < Self.askingTimeout }) ?? false):
            break
        default:
            toIdle()
        }
    }
}

// MARK: 文件系统（单测注入）

public struct AgentFileInfo: Equatable, Sendable {
    public var size: UInt64
    public var mtime: Date
    public var isDirectory: Bool
    public init(size: UInt64, mtime: Date, isDirectory: Bool) { self.size = size; self.mtime = mtime; self.isDirectory = isDirectory }
}

public protocol AgentFileSystem {
    func list(_ dir: String) -> [String]?
    func info(_ path: String) -> AgentFileInfo?
    func read(_ path: String, offset: UInt64, length: Int) -> Data?
}

public struct LocalAgentFileSystem: AgentFileSystem {
    public init() {}
    public func list(_ dir: String) -> [String]? { try? FileManager.default.contentsOfDirectory(atPath: dir) }
    public func info(_ path: String) -> AgentFileInfo? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (a[.modificationDate] as? Date) ?? .distantPast
        return AgentFileInfo(size: size, mtime: mtime, isDirectory: (a[.type] as? FileAttributeType) == .typeDirectory)
    }
    public func read(_ path: String, offset: UInt64, length: Int) -> Data? {
        guard length > 0, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            return try h.read(upToCount: length) ?? Data()
        } catch { return nil }
    }
}

// MARK: 读取器（一个工具一个，只在一个串行队列上用）

public final class AgentSessionReader {
    public static let tailBytes = 64 * 1024
    public static let chunkBytes = 1024 * 1024

    struct Cursor: Equatable { var offset: UInt64; var skipping: Bool }

    public let tool: AgentTool
    let root: String
    let fs: AgentFileSystem
    let calendar: Calendar
    public private(set) var sessions: [Int: AgentSession] = [:]
    private(set) var cursors: [Int: Cursor] = [:]
    /// 调试 / 单测：处理过的事件名（只有事件名）。
    public private(set) var eventLog: [String] = []
    public var keepsEventLog = false

    public init(tool: AgentTool, root: String, fs: AgentFileSystem = LocalAgentFileSystem(), calendar: Calendar = .current) {
        self.tool = tool
        var r = root
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        self.root = r
        self.fs = fs
        self.calendar = calendar
    }

    public func accepts(_ path: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        let name = (path as NSString).lastPathComponent
        switch tool {
        case .codex: return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        case .antigravity: return name == "transcript.jsonl"
        }
    }

    func key(_ path: String) -> Int {
        var h = Hasher()
        h.combine(String(path.dropFirst(root.count)))
        return h.finalize()
    }

    /// 启动：不扫历史（契约 §1.3）。
    public func start(now: Date) {
        for path in startupCandidates(now: now) {
            guard let info = fs.info(path), !info.isDirectory else { continue }
            let age = now.timeIntervalSince(info.mtime)
            // Codex 放宽到 30 分钟只为恢复「问你问题」；其余 10 分钟。
            let window = tool == .codex ? AgentSession.askingTimeout : AgentSession.workingTimeout
            guard age <= window else { continue }
            restore(path, info: info, now: now)
        }
    }

    func startupCandidates(now: Date) -> [String] {
        switch tool {
        case .codex:
            var out: [String] = []
            for back in [0, -1] {
                guard let d = calendar.date(byAdding: .day, value: back, to: now) else { continue }
                let c = calendar.dateComponents([.year, .month, .day], from: d)
                guard let y = c.year, let m = c.month, let dd = c.day else { continue }
                let dir = root + "/" + String(format: "%04d/%02d/%02d", y, m, dd)
                for name in fs.list(dir) ?? [] {
                    let p = dir + "/" + name
                    if accepts(p) { out.append(p) }
                }
            }
            return out
        case .antigravity:
            var out: [String] = []
            for child in fs.list(root) ?? [] {
                let base = root + "/" + child
                for p in [base + "/transcript.jsonl", base + "/.system_generated/logs/transcript.jsonl"] {
                    // 只 stat 不打开：10 分钟前的文件不打开。
                    if let i = fs.info(p), !i.isDirectory, now.timeIntervalSince(i.mtime) <= AgentSession.workingTimeout {
                        out.append(p)
                    }
                }
            }
            return out
        }
    }

    /// 只读末尾 64KB，按启动规则恢复。
    private func restore(_ path: String, info: AgentFileInfo, now: Date) {
        let k = key(path)
        let len = Int(min(info.size, UInt64(Self.tailBytes)))
        let start = info.size - UInt64(len)
        var session = AgentSession()
        var offset = info.size
        var skipping = false
        if len > 0, let data = fs.read(path, offset: start, length: len) {
            var lines = splitLines(data)
            if start > 0, !lines.complete.isEmpty { lines.complete.removeFirst() }  // 第一段是半行
            for line in lines.complete {
                handle(line, session: &session, now: info.mtime, restoring: true)
            }
            offset = start + UInt64(data.count - lines.remainder)
            if lines.remainder > AgentLineParser.maxLineBytes { offset = start + UInt64(data.count); skipping = true }
        }
        session.keepOnlyRestorable(mtime: info.mtime, now: now)
        sessions[k] = session
        cursors[k] = Cursor(offset: offset, skipping: skipping)
    }

    /// 文件有变化。返回 true = 这次没读完（超过 1MB），调用方接着再调一次。
    @discardableResult
    public func fileChanged(_ path: String, now: Date) -> Bool {
        guard accepts(path) else { return false }
        let k = key(path)
        guard let info = fs.info(path) else { remove(k); return false }
        guard !info.isDirectory else { return false }
        guard var cur = cursors[k], info.size >= cur.offset else {
            // 新文件或变小（截断 / 替换）：从头读，超过 64KB 只读末尾 64KB。
            sessions[k] = nil; cursors[k] = nil
            if info.size > UInt64(Self.tailBytes) {
                restore(path, info: info, now: now)
                return false
            }
            cursors[k] = Cursor(offset: 0, skipping: false)
            sessions[k] = AgentSession()
            return fileChanged(path, now: now)
        }
        guard info.size > cur.offset else { return false }
        let len = Int(min(info.size - cur.offset, UInt64(Self.chunkBytes)))
        guard let data = fs.read(path, offset: cur.offset, length: len), !data.isEmpty else { return false }
        var session = sessions[k] ?? AgentSession()
        let before = cur.offset
        let lines = splitLines(data)
        for (i, line) in lines.complete.enumerated() {
            if i == 0 && cur.skipping {  // 上次跳过的长行的剩余部分
                cur.skipping = false
                session.noteLine(at: now)
                continue
            }
            handle(line, session: &session, now: now, restoring: false)
        }
        if lines.remainder > AgentLineParser.maxLineBytes || (lines.complete.isEmpty && data.count >= Self.chunkBytes) {
            // 没有换行的超长半行：不等它补齐，直接跳过；Codex 有提问时只看它的前 1KB（只生效一次）。
            let isNewLine = !lines.complete.isEmpty || !cur.skipping
            if isNewLine {
                session.noteLine(at: now)
                if tool == .codex, let r = AgentLineParser.codexLong(Data(data.suffix(lines.remainder)), pending: session.pending) {
                    apply(r.event, session: &session, at: now)
                }
            }
            cur.skipping = true
            cur.offset += UInt64(data.count)
        } else {
            cur.offset += UInt64(data.count - lines.remainder)
        }
        session.advance(to: now)
        sessions[k] = session
        cursors[k] = cur
        // 只有读满 1MB 上限、而且确实往前读了，才需要接着读；等半行补齐的情况不重试。
        return len == Self.chunkBytes && cur.offset > before && cur.offset < info.size
    }

    public func fileRemoved(_ path: String) { remove(key(path)) }
    private func remove(_ k: Int) { sessions[k] = nil; cursors[k] = nil }

    private func handle(_ line: Data, session: inout AgentSession, now: Date, restoring: Bool) {
        session.noteLine(at: now)
        guard !line.isEmpty else { return }
        switch tool {
        case .codex:
            guard let r = AgentLineParser.codex(line, pending: session.pending) else { return }
            apply(r.event, session: &session, at: restoring ? (r.time ?? now) : now)
        case .antigravity:
            guard let e = AgentLineParser.antigravity(line) else { return }
            apply(e, session: &session, at: now)
        }
    }

    private func apply(_ e: AgentEvent, session: inout AgentSession, at t: Date) {
        session.apply(e, at: t)
        if keepsEventLog { eventLog.append(e.debugName) }
    }

    /// 按 \n 切：complete 是完整行（不含 \n），remainder 是最后没有换行的字节数。
    func splitLines(_ data: Data) -> (complete: [Data], remainder: Int) {
        var out: [Data] = []
        var start = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0A {
                out.append(data.subdata(in: start..<i))
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        return (out, data.distance(from: start, to: data.endIndex))
    }

    public func advance(now: Date) {
        for k in Array(sessions.keys) { sessions[k]?.advance(to: now) }
    }

    public func nextDeadline() -> Date? { sessions.values.compactMap(\.deadline).min() }

    /// 归并（契约 §1.5）。
    public func status(now: Date) -> AgentToolStatus {
        advance(now: now)
        return Self.merge(Array(sessions.values))
    }

    public static func merge(_ sessions: [AgentSession]) -> AgentToolStatus {
        let top = sessions.map(\.phase).max() ?? .idle
        guard top != .idle else { return .idle }
        let since = top >= .working ? sessions.filter { $0.phase == top }.compactMap(\.since).min() : nil
        return AgentToolStatus(phase: top, since: since)
    }

    public var sessionCount: Int { sessions.count }
}
