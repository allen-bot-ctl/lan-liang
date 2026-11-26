#if canImport(SQLite3)
import Foundation
import SQLite3

/// 磁盘缓存 ~/.lanliang/gemini-usage-cache.json（契约 0.1.5 §2）：只有路径、大小、修改时间和按日数字。
/// dbMtime / walMtime 是 1970 年起的微秒整数；没有 -wal 时 walSize、walMtime 记 0。
public struct GeminiUsageCacheFile: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var dbSize: Int64, dbMtime: Int64, walSize: Int64, walMtime: Int64
        public var days: [String: Int64]
        public var modelDays: DailyModelWeights?
    }
    public var version: Int
    public var entries: [String: Entry]

    public static func url(home: URL) -> URL { home.appendingPathComponent(".lanliang/gemini-usage-cache.json") }

    /// 读不了、坏 JSON、version 不是 1 → nil（当作没有缓存）。
    public static func load(_ url: URL) -> GeminiUsageCacheFile? {
        guard let d = FileManager.default.contents(atPath: url.path),
              let c = try? JSONDecoder().decode(GeminiUsageCacheFile.self, from: d), c.version == 1 else { return nil }
        return c
    }

    /// 目录 700、文件 600；同目录临时文件写好再 rename。
    public func write(_ url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(self)
        let tmp = dir.appendingPathComponent(".gemini-usage-cache.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if rename(tmp.path, url.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// 扫描 Antigravity 本机对话库（契约 0.1.4 §1/§5，0.1.5 §1/§2）。
/// 只读：每个库先把 db 和 -wal 复制到私有临时目录再打开副本，原文件不打开、不加锁、不改。
/// 缓存按 db 绝对路径，键为 (db 大小、db 修改时间、wal 大小、wal 修改时间)，没变就不复制不打开。
/// 不是线程安全的：调用方在一个后台串行队列里用它。
public final class GeminiHistoryScanner {
    /// 统计的目录（存在才读），同时也是同 id 修改时间相同时的优先顺序。不读 antigravity-backup。
    public static let roots = ["antigravity", "antigravity-ide", "antigravity-cli"]
    public static let maxBytes: Int64 = 512 << 20

    public struct Signature: Equatable {
        public var dbSize: Int64, dbMtime: Int64, walSize: Int64, walMtime: Int64   // 微秒；没有 wal 记 0
        public var latest: Date { Date(timeIntervalSince1970: Double(max(dbMtime, walMtime)) / 1e6) }
        public var hasWal: Bool { walMtime != 0 || walSize != 0 }
    }

    /// 三段计时（秒）：复制、SQLite 读取（不含解码）、解码。
    public struct Timings: Equatable {
        public var copy: Double = 0, sqlite: Double = 0, decode: Double = 0, total: Double = 0
    }

    struct Entry { var id: String; var path: URL; var sig: Signature }

    private let home: URL
    private let cacheURL: URL?
    private let calendar: () -> Calendar
    /// 成功读取的对话：路径 → (签名, 按日)。读取失败的不进缓存。
    private typealias CachedUsage = (sig: Signature, days: [String: Int64], modelDays: DailyModelWeights?)
    private var cache: [String: CachedUsage] = [:]
    private var diskLoaded = false

    /// 测试用计数：真正复制了几个库、打开了几个副本。
    public private(set) var copyCount = 0
    public private(set) var openCount = 0
    public var parseCount: Int { openCount }
    public private(set) var lastTimings = Timings()

    /// cacheURL 为 nil 时不读写磁盘缓存（只用内存缓存）。
    public init(home: URL, cacheURL: URL? = nil, calendar: @escaping () -> Calendar = { TokenSeries.calendar() }) {
        self.home = home; self.cacheURL = cacheURL; self.calendar = calendar
    }

    static func micros(_ d: Date?) -> Int64 { d.map { Int64(($0.timeIntervalSince1970 * 1e6).rounded()) } ?? 0 }

    static func signature(_ path: String) -> Signature? {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: path), (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let w = try? fm.attributesOfItem(atPath: path + "-wal")
        return Signature(dbSize: (a[.size] as? NSNumber)?.int64Value ?? 0,
                         dbMtime: micros(a[.modificationDate] as? Date),
                         walSize: (w?[.size] as? NSNumber)?.int64Value ?? 0,
                         walMtime: micros(w?[.modificationDate] as? Date))
    }

    /// 读磁盘缓存进内存（只读一次）；返回缓存里的结果供立即画图，没有缓存返回 nil。
    @discardableResult
    public func loadDiskCache() -> GeminiHistory? {
        if !diskLoaded {
            diskLoaded = true
            if let u = cacheURL, let f = GeminiUsageCacheFile.load(u) {
                for (p, e) in f.entries {
                    cache[p] = (Signature(dbSize: e.dbSize, dbMtime: e.dbMtime, walSize: e.walSize, walMtime: e.walMtime), e.days, e.modelDays)
                }
            }
        }
        guard !cache.isEmpty else { return nil }
        var daily: [String: Int64] = [:]
        var modelDaily: DailyModelWeights = [:]
        for c in cache.values {
            for (k, v) in c.days { daily[k, default: 0] += v }
            if let models = c.modelDays { ModelDistribution.merge(models, into: &modelDaily) }
        }
        let hasModelCache = cache.values.allSatisfy { $0.modelDays != nil }
        return GeminiHistory(foundDirectory: true, conversations: cache.count, failed: 0,
                             daily: daily, modelDaily: hasModelCache ? modelDaily : nil)
    }

    private func diskFile() -> GeminiUsageCacheFile {
        var entries: [String: GeminiUsageCacheFile.Entry] = [:]
        for (p, c) in cache {
            entries[p] = .init(dbSize: c.sig.dbSize, dbMtime: c.sig.dbMtime, walSize: c.sig.walSize,
                               walMtime: c.sig.walMtime, days: c.days, modelDays: c.modelDays)
        }
        return GeminiUsageCacheFile(version: 1, entries: entries)
    }

    /// 列目录、stat 文件，按对话 id 去重（取 db/-wal 最新修改时间那份）。.pb 跳过。
    func list() -> (found: Bool, entries: [Entry]) {
        let fm = FileManager.default
        var found = false
        var best: [String: Entry] = [:]
        for r in Self.roots {
            let dir = home.appendingPathComponent(".gemini").appendingPathComponent(r).appendingPathComponent("conversations")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            found = true
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names.sorted() where !n.hasPrefix(".") && n.hasSuffix(".db") {
                let u = dir.appendingPathComponent(n)
                guard let sig = Self.signature(u.path) else { continue }
                let e = Entry(id: String(n.dropLast(3)), path: u, sig: sig)
                if let old = best[e.id], !(e.sig.latest > old.sig.latest) { continue }
                best[e.id] = e
            }
        }
        return (found, best.values.sorted { $0.id < $1.id })
    }

    public func scan() -> GeminiHistory {
        let t0 = CFAbsoluteTimeGetCurrent()
        var tm = Timings()
        loadDiskCache()
        let before = diskFile()
        let (found, entries) = list()
        var next: [String: CachedUsage] = [:]
        var daily: [String: Int64] = [:]
        var modelDaily: DailyModelWeights = [:]
        var failed = 0
        for e in entries {
            let key = e.path.path
            let result: CachedUsage?
            if let old = cache[key], old.sig == e.sig, old.modelDays != nil {
                result = old
            } else {
                result = read(e, &tm)
            }
            if let result {
                next[key] = result
                for (k, v) in result.days { daily[k, default: 0] += v }
                if let models = result.modelDays { ModelDistribution.merge(models, into: &modelDaily) }
            } else { failed += 1 }
        }
        cache = next   // 不在目录里的、读取失败的都不留
        if let u = cacheURL {
            let after = diskFile()
            if after != before || !FileManager.default.fileExists(atPath: u.path) { try? after.write(u) }
        }
        tm.total = CFAbsoluteTimeGetCurrent() - t0
        lastTimings = tm
        return GeminiHistory(foundDirectory: found, conversations: entries.count, failed: failed,
                             daily: daily, modelDaily: modelDaily)
    }

    /// 复制（前后签名不一致就重来，最多 3 次）并解析；失败返回 nil。
    private func read(_ e: Entry, _ tm: inout Timings) -> CachedUsage? {
        guard e.sig.dbSize + e.sig.walSize <= Self.maxBytes else { return nil }
        let fm = FileManager.default
        for _ in 0..<3 {
            guard let before = Self.signature(e.path.path) else { return nil }
            guard before.dbSize + before.walSize <= Self.maxBytes else { return nil }
            let tc = CFAbsoluteTimeGetCurrent()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lanliang-agy-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: tmp) }
            guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil else { return nil }
            let db = tmp.appendingPathComponent("c.db")
            do {
                try fm.copyItem(at: e.path, to: db)
                if fm.fileExists(atPath: e.path.path + "-wal") {
                    try fm.copyItem(atPath: e.path.path + "-wal", toPath: db.path + "-wal")
                }
            } catch { tm.copy += CFAbsoluteTimeGetCurrent() - tc; continue }
            copyCount += 1
            tm.copy += CFAbsoluteTimeGetCurrent() - tc
            guard Self.signature(e.path.path) == before else { continue }
            guard let records = readRecords(db.path, &tm) else { return nil }
            let cal = calendar()
            var modelDays: DailyModelWeights = [:]
            for r in records.generations {
                let day = DayKey.of(r.at ?? before.latest, calendar: cal)
                ModelDistribution.append(r.usage.total, model: r.model, day: day, to: &modelDays)
            }
            return (before, GeminiConversation.daily(records.forTotals, fallback: before.latest, calendar: cal), modelDays)
        }
        return nil
    }

    /// 打开私有副本读取调用记录。
    /// 只读方式（SQLITE_OPEN_READONLY）打不开 WAL 模式的库：只读连接不能新建 -shm，而 -shm 不复制；
    /// immutable=1 又会忽略 -wal 里的数据。所以直接读写方式打开这份私有副本（只开一次），
    /// 并设 query_only 保证不写；原文件始终不碰。
    private func readRecords(_ path: String, _ tm: inout Timings)
        -> (forTotals: [GeminiCallRecord], generations: [(at: Date?, usage: GeminiCallUsage, model: String?)])? {
        let ts = CFAbsoluteTimeGetCurrent()
        var decode = 0.0
        defer { tm.sqlite += CFAbsoluteTimeGetCurrent() - ts - decode; tm.decode += decode }
        var h: OpaquePointer?
        openCount += 1
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let conn = h else {
            sqlite3_close(h); return nil
        }
        defer { sqlite3_close(conn) }
        sqlite3_busy_timeout(conn, 1000)
        guard sqlite3_exec(conn, "PRAGMA query_only=1", nil, nil, nil) == SQLITE_OK else { return nil }
        func query(_ sql: String, bind: Int64? = nil, _ row: (UnsafeRawBufferPointer) -> Void) -> Bool {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &st, nil) == SQLITE_OK, let s = st else { sqlite3_finalize(st); return false }
            defer { sqlite3_finalize(s) }
            if let b = bind { sqlite3_bind_int64(s, 1, b) }
            while true {
                let r = sqlite3_step(s)
                guard r == SQLITE_ROW else { return r == SQLITE_DONE }
                // 直接用 SQLite 的缓冲区解码，不拷贝成 Data。
                let n = Int(sqlite3_column_bytes(s, 0))
                let p = sqlite3_column_blob(s, 0)
                let t = CFAbsoluteTimeGetCurrent()
                row(UnsafeRawBufferPointer(start: p, count: p == nil ? 0 : n))
                decode += CFAbsoluteTimeGetCurrent() - t
            }
        }
        var tables = Set<String>()
        var st: OpaquePointer?
        if sqlite3_prepare_v2(conn, "SELECT name FROM sqlite_master WHERE type='table'", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 0) { tables.insert(String(cString: c)) } }
            sqlite3_finalize(st)
        } else { sqlite3_finalize(st); return nil }
        let hasSteps = tables.contains("steps"), hasGens = tables.contains("gen_metadata")
        guard hasSteps || hasGens else { return nil }
        var out: [GeminiCallRecord] = []
        if hasSteps {
            guard query("SELECT metadata FROM steps", { b in
                if let m = ProtoScan.stepMetadata(b), let u = m.usage { out.append(GeminiCallRecord(at: m.at, usage: u)) }
            }) else { return nil }
        }
        guard hasGens else { return (out, []) }
        var gens: [(usage: GeminiCallUsage, step: Int64?, model: String?, at: Date?, id: Data?)] = []
        guard query("SELECT data FROM gen_metadata", { b in
            if let g = ProtoScan.genData(b), let u = g.usage {
                gens.append((u, g.step, g.model, g.at, g.generationID))
            }
        }) else { return out.isEmpty ? nil : (out, []) }
        // Don't change the established daily totals: use steps first, or their legacy fallback timestamp.
        var stepAt: [Int64: Date] = [:]
        if hasSteps {
            for s in Set(gens.compactMap { g in (out.isEmpty || g.at == nil) ? g.step : nil }) {
                guard query("SELECT metadata FROM steps WHERE idx = ?", bind: s, { b in
                    if let at = ProtoScan.stepMetadata(b)?.at { stepAt[s] = at }
                }) else { return out.isEmpty ? nil : (out, []) }
            }
        }
        let totals = out.isEmpty ? gens.map { GeminiCallRecord(at: $0.step.flatMap { stepAt[$0] }, usage: $0.usage) } : out
        var seen = Set<Data>()
        let models = gens.compactMap { g -> (Date?, GeminiCallUsage, String?)? in
            if let id = g.id, !seen.insert(id).inserted { return nil }
            return (g.at ?? g.step.flatMap { stepAt[$0] }, g.usage, g.model)
        }
        return (totals, models)
    }

    /// 0.1.4 的读法（取 idx+metadata 全量、ProtoMessage 全解码）：只给单测比对逐日结果用。
    static func readRowsV014(_ path: String) -> (steps: [(idx: Int64, metadata: Data)], gens: [Data])? {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let conn = h else {
            sqlite3_close(h); return nil
        }
        defer { sqlite3_close(conn) }
        func rows(_ sql: String) -> [(Int64, Data)]? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); return nil }
            defer { sqlite3_finalize(st) }
            var out: [(Int64, Data)] = []
            while sqlite3_step(st) == SQLITE_ROW {
                let n = Int(sqlite3_column_bytes(st, 1))
                let d = sqlite3_column_blob(st, 1).map { Data(bytes: $0, count: n) } ?? Data()
                out.append((sqlite3_column_int64(st, 0), d))
            }
            return out
        }
        let s = rows("SELECT idx, metadata FROM steps ORDER BY idx")
        let g = rows("SELECT idx, data FROM gen_metadata ORDER BY idx")
        guard s != nil || g != nil else { return nil }
        return ((s ?? []).map { (idx: $0.0, metadata: $0.1) }, (g ?? []).map { $0.1 })
    }
}
#endif
