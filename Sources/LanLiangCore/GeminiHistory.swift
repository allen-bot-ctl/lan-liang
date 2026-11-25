import Foundation

/// Antigravity 一次模型调用的 token 用量（steps.metadata 字段 9，或 gen_metadata.data.1.4）。
/// 子字段：2 输入、3 输出、4 缓存写入、5 缓存读取、9 思考输出、10 回复输出（契约 0.1.4 §2）。
public struct GeminiCallUsage: Equatable {
    public var input: Int64, output: Int64, cacheWrite: Int64, cacheRead: Int64, thinking: Int64, response: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0,
                thinking: Int64 = 0, response: Int64 = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
        self.thinking = thinking; self.response = response
    }

    /// 每次调用计入的 token（契约 §3 口径）。口径若要改（例如输入已含缓存读取），只改这一处。
    public static func tokenTotal(_ u: GeminiCallUsage) -> Int64 {
        u.input + u.output + u.cacheRead + u.cacheWrite
    }

    public var total: Int64 { GeminiCallUsage.tokenTotal(self) }

    /// 字段 3 为 0 时输出 = 9 + 10；四项计数全为 0（没有 token 计数的调用）返回 nil。
    public static func parse(_ m: ProtoMessage) -> GeminiCallUsage? {
        var u = GeminiCallUsage(input: m.count(2), output: m.count(3), cacheWrite: m.count(4), cacheRead: m.count(5),
                                thinking: m.count(9), response: m.count(10))
        if u.output == 0 { u.output = u.thinking + u.response }
        return (u.input > 0 || u.output > 0 || u.cacheRead > 0 || u.cacheWrite > 0) ? u : nil
    }
}

public struct GeminiCallRecord: Equatable {
    public var at: Date?
    public var usage: GeminiCallUsage
}

public enum GeminiConversation {
    /// 一个对话库的全部调用。
    /// 只要有任何一步带字段 9 就只用 steps；一步都没有时退回 gen_metadata（时间取 last_step_index+1 那一步）。
    /// 坏的 protobuf 记录跳过这一条。
    public static func records(steps: [(idx: Int64, metadata: Data)], gens: [Data]) -> [GeminiCallRecord] {
        var stepAt: [Int64: Date] = [:]
        var out: [GeminiCallRecord] = []
        for s in steps {
            guard let meta = ProtoMessage(s.metadata) else { continue }
            let at = meta.timestamp(1)
            if let at = at { stepAt[s.idx] = at }
            guard let um = meta.message(9), let u = GeminiCallUsage.parse(um) else { continue }
            out.append(GeminiCallRecord(at: at, usage: u))
        }
        if !out.isEmpty { return out }
        for d in gens {
            guard let top = ProtoMessage(d), let call = top.message(1),
                  let um = call.message(4), let u = GeminiCallUsage.parse(um) else { continue }
            var step: Int64?
            for e in call.messages(20) where e.string(1) == "last_step_index" {
                if let n = e.string(2).flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), n >= 0 { step = n + 1 }
            }
            out.append(GeminiCallRecord(at: step.flatMap { stepAt[$0] }, usage: u))
        }
        return out
    }

    /// 按本地日历日累加；没有时间的调用按 fallback（该对话 db/-wal 的最新修改时间）计。
    public static func daily(_ recs: [GeminiCallRecord], fallback: Date, calendar: Calendar) -> [String: Int64] {
        var d: [String: Int64] = [:]
        for r in recs { d[DayKey.of(r.at ?? fallback, calendar: calendar), default: 0] += r.usage.total }
        return d
    }
}

/// 一次扫描的结果（面板用；也用于模拟数据）。
public struct GeminiHistory: Codable, Equatable {
    /// 三个目录里至少有一个存在。
    public var foundDirectory: Bool
    /// 去重后参与统计的对话库个数（不含 .pb）。
    public var conversations: Int
    /// 读取失败的对话个数。
    public var failed: Int
    public var daily: [String: Int64]

    public init(foundDirectory: Bool, conversations: Int, failed: Int, daily: [String: Int64]) {
        self.foundDirectory = foundDirectory; self.conversations = conversations; self.failed = failed; self.daily = daily
    }

    public enum Display: Equatable { case noDirectory, empty, allFailed, chart(failed: Int) }

    public var display: Display {
        if !foundDirectory { return .noDirectory }
        if conversations > 0, failed >= conversations { return .allFailed }
        if daily.values.reduce(0, +) <= 0 { return .empty }
        return .chart(failed: failed)
    }

    /// 状态文案（契约 §4）；画图时返回 nil。
    public static func message(_ d: Display) -> String? {
        switch d {
        case .noDirectory: return "没有找到 Antigravity 本机对话记录"
        case .empty: return "Antigravity 本机暂无 Token 用量"
        case .allFailed: return "Antigravity 对话记录读取失败"
        case .chart: return nil
        }
    }
}
