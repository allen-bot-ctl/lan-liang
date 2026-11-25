import Foundation

/// 跳读式 protobuf 解码（契约 0.1.5 §1）：直接在原始字节上按 wire type 走，
/// 不认识的字段只跳过长度，不拷贝、不建对象、不递归。结构坏了（截断、group、半个 varint）返回 false。
public enum ProtoScan {
    public enum Field {
        case varint(UInt64)
        case fixed(UInt64)
        case bytes(UnsafeRawBufferPointer)
    }

    /// 逐个字段回调；body 只在需要的字段上做事。
    @discardableResult
    public static func forEach(_ b: UnsafeRawBufferPointer, _ body: (UInt64, Field) -> Void) -> Bool {
        var i = 0
        let n = b.count
        @inline(__always) func varint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < n, shift < 64 {
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return r }
                shift += 7
            }
            return nil
        }
        while i < n {
            guard let key = varint() else { return false }
            let num = key >> 3
            guard num != 0 else { return false }
            switch key & 7 {
            case 0:
                guard let v = varint() else { return false }
                body(num, .varint(v))
            case 1:
                guard i + 8 <= n else { return false }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8
                body(num, .fixed(v))
            case 2:
                guard let len = varint(), len <= UInt64(n - i) else { return false }
                let s = UnsafeRawBufferPointer(rebasing: b[i..<(i + Int(len))])
                i += Int(len)
                body(num, .bytes(s))
            case 5:
                guard i + 4 <= n else { return false }
                var v: UInt64 = 0
                for k in 0..<4 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 4
                body(num, .fixed(v))
            default:
                return false
            }
        }
        return true
    }

    /// 字段 1 的时间（Timestamp：1 秒、2 纳秒）；与 ProtoMessage.timestamp 规则相同。
    static func timestamp(_ b: UnsafeRawBufferPointer) -> Date? {
        var s: UInt64?, ns: UInt64?
        guard forEach(b, { num, f in
            switch (num, f) {
            case (1, .varint(let v)), (1, .fixed(let v)): s = v
            case (2, .varint(let v)), (2, .fixed(let v)): ns = v
            default: break
            }
        }) else { return nil }
        guard let sec = s, sec > 0, sec < (1 << 40) else { return nil }
        let nano = ns ?? 0
        guard nano < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sec) + TimeInterval(nano) / 1e9)
    }

    /// 用量消息：只取 2、3、4、5、9、10；规则同 GeminiCallUsage.parse。
    static func usage(_ b: UnsafeRawBufferPointer) -> GeminiCallUsage? {
        var c = [Int64](repeating: 0, count: 11)
        guard forEach(b, { num, f in
            switch f {
            case .varint(let v), .fixed(let v):
                if num == 2 || num == 3 || num == 4 || num == 5 || num == 9 || num == 10 {
                    c[Int(num)] = Int64(min(v, UInt64(Int64.max)))
                }
            case .bytes: break
            }
        }) else { return nil }
        var u = GeminiCallUsage(input: c[2], output: c[3], cacheWrite: c[4], cacheRead: c[5], thinking: c[9], response: c[10])
        if u.output == 0 { u.output = u.thinking + u.response }
        return (u.input > 0 || u.output > 0 || u.cacheRead > 0 || u.cacheWrite > 0) ? u : nil
    }

    /// steps.metadata：只看字段 1（时间）和 9（用量），各取最后一个；整条结构坏了返回 nil（跳过这一条）。
    public static func stepMetadata(_ b: UnsafeRawBufferPointer) -> (at: Date?, usage: GeminiCallUsage?)? {
        var t: UnsafeRawBufferPointer?, u: UnsafeRawBufferPointer?
        guard forEach(b, { num, f in
            if case .bytes(let s) = f { if num == 1 { t = s } else if num == 9 { u = s } }
        }) else { return nil }
        return (t.flatMap(timestamp), u.flatMap(usage))
    }

    /// gen_metadata.data：只看字段 1 下的字段 4（用量）和字段 20（键值对，取 last_step_index）。
    /// 返回 (用量, 响应所在步 = last_step_index + 1)；结构坏或没有调用信息返回 nil。
    public static func genData(_ b: UnsafeRawBufferPointer) -> (usage: GeminiCallUsage?, step: Int64?)? {
        var call: UnsafeRawBufferPointer?
        guard forEach(b, { num, f in if num == 1, case .bytes(let s) = f { call = s } }), let c = call else { return nil }
        var usageBytes: UnsafeRawBufferPointer?
        var step: Int64?
        let ok = forEach(c) { num, f in
            guard case .bytes(let s) = f else { return }
            if num == 4 { usageBytes = s; return }
            guard num == 20 else { return }
            var k: UnsafeRawBufferPointer?, v: UnsafeRawBufferPointer?
            guard forEach(s, { n2, f2 in
                if case .bytes(let x) = f2 { if n2 == 1 { k = x } else if n2 == 2 { v = x } }
            }), let key = k, key.elementsEqual("last_step_index".utf8) else { return }
            if let val = v, let str = String(bytes: val, encoding: .utf8),
               let n = Int64(str.trimmingCharacters(in: .whitespaces)), n >= 0 { step = n + 1 }
        }
        guard ok else { return nil }
        return (usageBytes.flatMap(usage), step)
    }
}
