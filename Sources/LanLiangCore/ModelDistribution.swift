import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Local per-day weights, split by provider and never added across providers.
public typealias DailyModelWeights = [String: [String: Int64]]

public enum ModelDistribution {
    public static let unknown = "未知模型"
    public static let other = "其他模型"

    public struct Share: Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        /// Share in tenths of a percent.
        public let tenths: Int
    }

    public static func name(_ value: String?) -> String {
        guard let s = value?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.utf8.count <= 128, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return unknown }
        if ["unknown", "unspecified", "default", "auto", "0", "model_unspecified"].contains(s.lowercased()) {
            return unknown
        }
        return s == other ? "其他（原始名称）" : s
    }

    public static func append(_ weight: Int64, model: String?, day: String, to days: inout DailyModelWeights) {
        guard weight > 0 else { return }
        let model = name(model)
        let old = days[day]?[model] ?? 0
        let (sum, overflow) = old.addingReportingOverflow(weight)
        days[day, default: [:]][model] = overflow ? Int64.max : sum
    }

    public static func merge(_ add: DailyModelWeights, into dest: inout DailyModelWeights) {
        for (day, models) in add {
            for (model, weight) in models { append(weight, model: model, day: day, to: &dest) }
        }
    }

    public static func shares(_ days: DailyModelWeights, start: String, through end: String,
                              maxNamedModels: Int = 5) -> [Share] {
        var grouped: [String: Double] = [:]
        for (day, models) in days where day >= start && day <= end {
            for (model, n) in models where n > 0 { grouped[name(model), default: 0] += Double(n) }
        }
        let order = grouped.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
        let fixed = order.filter { $0.key != unknown }
        let limit = max(0, maxNamedModels)
        var rows = Array(fixed.prefix(limit))
        let remainder = fixed.dropFirst(limit).reduce(0.0) { $0 + $1.value }
        if remainder > 0 { rows.append((other, remainder)) }
        if let unclassified = grouped[unknown] { rows.append((unknown, unclassified)) }
        let total = rows.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return [] }
        let raw = rows.map { $0.value / total * 1000 }
        var units = raw.map { Int($0.rounded(.down)) }
        let left = max(0, 1000 - units.reduce(0, +))
        let rank = raw.indices.sorted {
            let x = raw[$0] - Double(units[$0]), y = raw[$1] - Double(units[$1])
            return x != y ? x > y : $0 < $1
        }
        for i in rank.prefix(left) { units[i] += 1 }
        return zip(rows, units).map { Share(name: $0.0.key, tenths: $0.1) }
    }
}

/// Narrow read-only metadata query. No transcript, prompt, auth, or rollout column is selected.
public enum CodexModelActivity {
    public static func read(db: URL, since: Date, now: Date, calendar: Calendar) -> DailyModelWeights? {
        #if canImport(SQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let conn = handle else {
            sqlite3_close(handle); return nil
        }
        defer { sqlite3_close(conn) }
        sqlite3_busy_timeout(conn, 150)
        guard sqlite3_exec(conn, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        let sql = """
        SELECT model, updated_at FROM threads
        WHERE updated_at >= ? AND updated_at <= ? AND tokens_used > 0
        """
        guard sqlite3_prepare_v2(conn, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            sqlite3_finalize(statement); return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(now.timeIntervalSince1970))
        var days: DailyModelWeights = [:]
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return days }
            guard status == SQLITE_ROW else { return nil }
            let day = DayKey.of(Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))), calendar: calendar)
            let n = sqlite3_column_bytes(stmt, 0)
            let model = n > 0 && n <= 128 ? sqlite3_column_text(stmt, 0).flatMap {
                String(bytes: UnsafeBufferPointer(start: $0, count: Int(n)), encoding: .utf8)
            } : nil
            ModelDistribution.append(1, model: model, day: day, to: &days)
        }
        #else
        return nil
        #endif
    }
}
