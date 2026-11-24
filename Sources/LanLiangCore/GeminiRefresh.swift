import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 用 refresh_token 换新 Gemini（Antigravity）访问令牌：只在内存里用，不写回任何地方。
public enum GeminiTokenRefresh {
    /// 发请求的方式（测试里换成假的）：返回响应体和 HTTP 状态码。
    public typealias Transport = (URLRequest) async throws -> (Data, Int)

    public struct Failed: Error, Equatable {}

    public static func request(refreshToken: String, clientID: String, clientSecret: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                           URLQueryItem(name: "refresh_token", value: refreshToken),
                           URLQueryItem(name: "client_id", value: clientID),
                           URLQueryItem(name: "client_secret", value: clientSecret)]
        // 表单里 + 要转义，否则会被当成空格
        req.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        req.timeoutInterval = 20
        return req
    }

    /// 解析 token 接口响应；没有 access_token 返回 nil。expires_in 缺失按 1 小时。
    public static func parse(_ data: Data, now: Date) -> (accessToken: String, expiry: Date)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let at = obj["access_token"] as? String, !at.isEmpty else { return nil }
        let secs = looseDouble(obj["expires_in"]) ?? 3_600
        return (at, now.addingTimeInterval(secs))
    }

    public static func refresh(refreshToken: String, clientID: String, clientSecret: String,
                               now: Date, transport: Transport) async throws -> (accessToken: String, expiry: Date) {
        guard !refreshToken.isEmpty, !clientID.isEmpty, !clientSecret.isEmpty else { throw Failed() }
        let req = request(refreshToken: refreshToken, clientID: clientID, clientSecret: clientSecret)
        let (data, code): (Data, Int)
        do { (data, code) = try await transport(req) } catch { throw Failed() }
        guard (200..<300).contains(code), let r = parse(data, now: now) else { throw Failed() }
        return r
    }
}
