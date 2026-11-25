#if canImport(SQLite3)
import Foundation
import SQLite3

/// 扫描 Antigravity 本机对话库（契约 0.1.4 §1/§5）。
/// 只读：每个库先把 db 和 -wal 复制到私有临时目录再用 SQLite 只读打开副本，原文件不打开、不加锁、不改。
/// 内存缓存按 db 绝对路径，键为 (db 大小、db 修改时间、wal 大小、wal 修改时间)，没变就不复制不重读。
/// 不是线程安全的：调用方在一个后台串行队列里用它。
public final class GeminiHistoryScanner {
    /// 统计的目录（存在才读），同时也是同 id 修改时间相同时的优先顺序。不读 antigravity-backup。
    public static let roots = ["antigravity", "antigravity-ide", "antigravity-cli"]
    public static let maxBytes: Int64 = 512 << 20

    public struct Signature: Equatable {
        public var dbSize: Int64, dbMtime: Date, walSize: Int64, walMtime: Date?
        public var latest: Date { max(dbMtime, walMtime ?? .distantPast) }
    }

    struct Entry { var id: String; var path: URL; var sig: Signature }
    struct Cached { var sig: Signature; var daily: [String: Int64]?; }   // daily nil = 读取失败

    private let home: URL
    private let calendar: () -> Calendar
    private var cache: [String: Cached] = [:]

    /// 测试用：真正复制并解析了几个库。
    public private(set) var parseCount = 0

    public init(home: URL, calendar: @escaping () -> Calendar = { TokenSeries.calendar() }) {
        self.home = home; self.calendar = calendar
    }

    static func signature(_ path: String) -> Signature? {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: path), (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let w = try? fm.attributesOfItem(atPath: path + "-wal")
        return Signature(dbSize: (a[.size] as? NSNumber)?.int64Value ?? 0,
                         dbMtime: (a[.modificationDate] as? Date) ?? .distantPast,
                         walSize: (w?[.size] as? NSNumber)?.int64Value ?? 0,
                         walMtime: w?[.modificationDate] as? Date)
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
        let (found, entries) = list()
        var next: [String: Cached] = [:]
        var daily: [String: Int64] = [:]
        var failed = 0
        for e in entries {
            let key = e.path.path
            let c: Cached
            if let old = cache[key], old.sig == e.sig {
                c = old
            } else {
                parseCount += 1
                let (sig, d) = read(e)
                c = Cached(sig: sig ?? e.sig, daily: d)
            }
            next[key] = c
            if let d = c.daily { for (k, v) in d { daily[k, default: 0] += v } } else { failed += 1 }
        }
        cache = next   // 不在目录里的条目随之删掉
        return GeminiHistory(foundDirectory: found, conversations: entries.count, failed: failed, daily: daily)
    }

    /// 复制（前后签名不一致就重来，最多 3 次）并解析；失败返回 daily = nil。
    private func read(_ e: Entry) -> (Signature?, [String: Int64]?) {
        guard e.sig.dbSize + e.sig.walSize <= Self.maxBytes else { return (e.sig, nil) }
        let fm = FileManager.default
        for _ in 0..<3 {
            guard let before = Self.signature(e.path.path) else { return (nil, nil) }
            guard before.dbSize + before.walSize <= Self.maxBytes else { return (before, nil) }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lanliang-agy-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: tmp) }
            guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil else { return (before, nil) }
            let db = tmp.appendingPathComponent("c.db")
            do {
                try fm.copyItem(at: e.path, to: db)
                if before.walMtime != nil, fm.fileExists(atPath: e.path.path + "-wal") {
                    try fm.copyItem(atPath: e.path.path + "-wal", toPath: db.path + "-wal")
                }
            } catch { continue }
            guard Self.signature(e.path.path) == before else { continue }
            // 副本只读打开；个别系统上只读连接建不了 -shm 时，退回读写打开私有副本（原文件始终不碰）。
            guard let rows = Self.readRows(db.path, flags: SQLITE_OPEN_READONLY)
                ?? Self.readRows(db.path, flags: SQLITE_OPEN_READWRITE) else { return (before, nil) }
            let recs = GeminiConversation.records(steps: rows.steps, gens: rows.gens)
            return (before, GeminiConversation.daily(recs, fallback: before.latest, calendar: calendar()))
        }
        return (nil, nil)
    }

    /// 只读打开副本，取 steps(idx, metadata) 和 gen_metadata(data)；两张表都没有返回 nil。
    static func readRows(_ path: String, flags: Int32) -> (steps: [(idx: Int64, metadata: Data)], gens: [Data])? {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let conn = h else {
            sqlite3_close(h); return nil
        }
        defer { sqlite3_close(conn) }
        sqlite3_busy_timeout(conn, 1000)
        func query(_ sql: String, _ row: (OpaquePointer) -> Void) -> Bool {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &st, nil) == SQLITE_OK, let s = st else { sqlite3_finalize(st); return false }
            defer { sqlite3_finalize(s) }
            while true {
                let r = sqlite3_step(s)
                if r == SQLITE_ROW { row(s) } else { return r == SQLITE_DONE }
            }
        }
        func blob(_ s: OpaquePointer, _ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(s, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
        }
        var tables = Set<String>()
        guard query("SELECT name FROM sqlite_master WHERE type='table'", { s in
            if let c = sqlite3_column_text(s, 0) { tables.insert(String(cString: c)) }
        }) else { return nil }
        guard tables.contains("steps") || tables.contains("gen_metadata") else { return nil }
        var steps: [(idx: Int64, metadata: Data)] = [], gens: [Data] = []
        if tables.contains("steps"),
           !query("SELECT idx, metadata FROM steps ORDER BY idx", { s in steps.append((sqlite3_column_int64(s, 0), blob(s, 1))) }) {
            return nil
        }
        if tables.contains("gen_metadata"),
           !query("SELECT data FROM gen_metadata ORDER BY idx", { s in gens.append(blob(s, 0)) }) {
            return nil
        }
        return (steps, gens)
    }
}
#endif
