import Foundation

/// 模拟数据（env LANLIANG_FAKE=<json 路径> 或 --debug-fake=<路径>），CI 截图和测试不需要真实登录。
public struct FakeData: Codable, Equatable {
    public var now: Date?
    public var codex: ServiceSnapshot
    public var gemini: ServiceSnapshot
    /// nil = 官方接口失败（柱高用本机值，标题旁写「仅本机」）。
    public var official: [String: Int64]?
    public var local: [String: Int64]
    /// Gemini 本机 Token 历史；nil = 首次扫描没完成（面板显示「正在统计…」）。
    public var geminiHistory: GeminiHistory?

    public static func decode(_ data: Data) throws -> FakeData {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let s = try c.decode(String.self)
            guard let date = parseFlexibleDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return try d.decode(FakeData.self, from: data)
    }
}
