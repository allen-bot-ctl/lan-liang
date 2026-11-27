import Foundation
import CoreServices

/// 0.4.0 会话状态监听（契约 docs/changes/0.4.0.md §1.3）：FSEvents（延迟 1 秒、文件级事件）监听两个目录，
/// 回调和读文件都在后台串行队列；主线程只收归并后的 AgentSnapshot。不轮询；到点用一次性定时器。
/// 任何失败都只让「会话」显示空闲。
final class AgentWatcher {
    struct Roots { var codex: String; var antigravity: String }

    static func defaultRoots() -> Roots {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        let codexHome = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        return Roots(codex: codexHome + "/sessions", antigravity: home + "/.gemini/antigravity/brain")
    }

    /// 截图 / CI 用的假目录：<root>/codex/sessions、<root>/antigravity/brain。
    static func roots(under root: String) -> Roots {
        Roots(codex: root + "/codex/sessions", antigravity: root + "/antigravity/brain")
    }

    private final class Stream {
        let tool: AgentTool
        weak var owner: AgentWatcher?
        var ref: FSEventStreamRef?
        init(tool: AgentTool, owner: AgentWatcher) { self.tool = tool; self.owner = owner }
    }

    private let roots: Roots
    private let queue = DispatchQueue(label: "lanliang.agent-status", qos: .utility)
    private var readers: [AgentTool: AgentSessionReader] = [:]
    private var streams: [AgentTool: Stream] = [:]
    private var enabled: Set<AgentTool> = []
    private var deadlineItem: DispatchWorkItem?
    private var lastPublished: AgentSnapshot?
    var keepsEventLog = false
    /// 主线程回调；只在归并结果变化时调用。
    var onChange: (AgentSnapshot) -> Void = { _ in }

    init(roots: Roots) { self.roots = roots }

    deinit {
        for s in streams.values { stop(s) }
    }

    /// 跟随「监听服务」，并顺带看一次目录有没有出现（随额度刷新调用，不另加轮询）。
    func update(codex: Bool, antigravity: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            var want: Set<AgentTool> = []
            if codex { want.insert(.codex) }
            if antigravity { want.insert(.antigravity) }
            self.enabled = want
            for t in AgentTool.allCases where !want.contains(t) {
                if let s = self.streams.removeValue(forKey: t) { self.stop(s) }
                self.readers[t] = nil
            }
            for t in want where self.readers[t] == nil { self.begin(t) }
            self.publish()
        }
    }

    var isWatching: Bool { queue.sync { !streams.isEmpty } }
    func watching(_ t: AgentTool) -> Bool { queue.sync { streams[t] != nil } }
    func eventLog(_ t: AgentTool) -> [String] { queue.sync { readers[t]?.eventLog ?? [] } }

    private func root(_ t: AgentTool) -> String { t == .codex ? roots.codex : roots.antigravity }

    private func begin(_ t: AgentTool) {
        // 目录不存在：这个工具空闲，等下次额度刷新再看。FSEvents 报的是解析过符号链接的真实路径。
        guard let real = realpath(root(t), nil) else { return }
        let path = String(cString: real)
        free(real)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        let reader = AgentSessionReader(tool: t, root: path)
        reader.keepsEventLog = keepsEventLog
        let s = Stream(tool: t, owner: self)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(s).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let s = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var list: [String] = []
            for i in 0..<min(count, array.count) { if let p = array[i] as? String { list.append(p) } }
            s.owner?.changed(s.tool, paths: list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let ref = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [path] as CFArray,
                                            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        s.ref = ref
        FSEventStreamSetDispatchQueue(ref, queue)
        guard FSEventStreamStart(ref) else { stop(s); return }
        readers[t] = reader
        streams[t] = s
        reader.start(now: Date())
    }

    private func stop(_ s: Stream) {
        guard let ref = s.ref else { return }
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        s.ref = nil
    }

    /// 在 queue 上（FSEvents 回调）。
    private func changed(_ t: AgentTool, paths: [String]) {
        guard enabled.contains(t), let reader = readers[t] else { return }
        var seen = Set<String>()
        for p in paths where reader.accepts(p) && seen.insert(p).inserted {
            if reader.fileChanged(p, now: Date()) { scheduleMore(t, path: p) }
        }
        publish()
    }

    /// 一次最多读 1MB，剩下的排到队列后面接着读。
    private func scheduleMore(_ t: AgentTool, path: String) {
        queue.async { [weak self] in
            guard let self, let reader = self.readers[t] else { return }
            if reader.fileChanged(path, now: Date()) { self.scheduleMore(t, path: path) }
            self.publish()
        }
    }

    private func publish() {
        let now = Date()
        var snap = AgentSnapshot()
        if enabled.contains(.codex) { snap.codex = readers[.codex]?.status(now: now) ?? .idle }
        if enabled.contains(.antigravity) { snap.antigravity = readers[.antigravity]?.status(now: now) ?? .idle }
        // 一次性定时器：排到最近的到点时间，到点只触发一次。
        deadlineItem?.cancel()
        deadlineItem = nil
        if let d = readers.values.compactMap({ $0.nextDeadline() }).min() {
            let item = DispatchWorkItem { [weak self] in self?.publish() }
            deadlineItem = item
            queue.asyncAfter(deadline: .now() + max(0.05, d.timeIntervalSince(now) + 0.05), execute: item)
        }
        guard snap != lastPublished else { return }
        lastPublished = snap
        DispatchQueue.main.async { [weak self] in self?.onChange(snap) }
    }
}
