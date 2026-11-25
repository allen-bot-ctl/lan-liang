import Foundation

/// 极简 protobuf 读取（按 wire format 规范自写）：只认 varint(0)、fixed64(1)、length-delimited(2)、fixed32(5)。
/// 遇到 group(3/4) 或截断，整条消息视为无效。同号字段取最后一个（protobuf 标量 last-wins）。
public struct ProtoMessage {
    public enum Value { case varint(UInt64), fixed(UInt64), bytes(Data) }
    public private(set) var fields: [(num: UInt64, value: Value)] = []

    public init?(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return r }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint(), key >> 3 != 0 else { return nil }
            let num = key >> 3
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                fields.append((num, .varint(v)))
            case 1:
                guard i + 8 <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8; fields.append((num, .fixed(v)))
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return nil }
                fields.append((num, .bytes(Data(b[i..<(i + Int(n))])))); i += Int(n)
            case 5:
                guard i + 4 <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<4 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 4; fields.append((num, .fixed(v)))
            default:
                return nil
            }
        }
    }

    public func uint(_ n: UInt64) -> UInt64? {
        for f in fields.reversed() where f.num == n {
            switch f.value { case .varint(let v), .fixed(let v): return v; case .bytes: continue }
        }
        return nil
    }
    public func count(_ n: UInt64) -> Int64 { Int64(min(uint(n) ?? 0, UInt64(Int64.max))) }
    public func bytes(_ n: UInt64) -> Data? {
        for f in fields.reversed() where f.num == n { if case .bytes(let d) = f.value { return d } }
        return nil
    }
    public func message(_ n: UInt64) -> ProtoMessage? { bytes(n).flatMap(ProtoMessage.init) }
    public func messages(_ n: UInt64) -> [ProtoMessage] {
        fields.compactMap { f in
            guard f.num == n, case .bytes(let d) = f.value else { return nil }
            return ProtoMessage(d)
        }
    }
    public func string(_ n: UInt64) -> String? { bytes(n).flatMap { String(data: $0, encoding: .utf8) } }

    /// google.protobuf.Timestamp {1 seconds, 2 nanos}；0 或离谱值返回 nil。
    public func timestamp(_ n: UInt64) -> Date? {
        guard let m = message(n), let s = m.uint(1), s > 0, s < (1 << 40) else { return nil }
        let ns = m.uint(2) ?? 0
        guard ns < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(s) + TimeInterval(ns) / 1e9)
    }
}
