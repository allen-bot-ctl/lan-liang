import Foundation

/// 读 Antigravity 官方登录（契约 0.3.14 §1）。
/// 钥匙串项（service gemini / account antigravity）是 Antigravity 通过 /usr/bin/security 写入的，
/// 用同一个程序读不会弹授权窗口。栏量只读不写，输出只在内存里解析，不打日志。
public enum GeminiOfficialSource {
    public enum Read: Equatable {
        /// 退出码 0：读到的原始值（还没解码）。
        case found(Data)
        /// 退出码 44：没有这一项，即 Antigravity 没登录。
        case notFound
        /// 超时、启动失败或其他退出码：这次没读到，下个周期再试。
        case unavailable
    }

    /// 一次子进程运行的结果；测试里换成假的。
    public struct Outcome: Equatable {
        public var stdout: Data
        public var exitCode: Int32
        public var timedOut: Bool
        public init(stdout: Data, exitCode: Int32, timedOut: Bool = false) {
            self.stdout = stdout; self.exitCode = exitCode; self.timedOut = timedOut
        }
    }

    public static let securityPath = "/usr/bin/security"
    public static let arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
    public static let notFoundExitCode: Int32 = 44
    public static let timeout: TimeInterval = 5

    public static func interpret(_ o: Outcome?) -> Read {
        guard let o, !o.timedOut else { return .unavailable }
        switch o.exitCode {
        case 0: return o.stdout.isEmpty ? .unavailable : .found(o.stdout)
        case notFoundExitCode: return .notFound
        default: return .unavailable
        }
    }

    public static func readKeychainItem(run: () -> Outcome? = { runSecurity() }) -> Read {
        interpret(run())
    }

    /// 跑 `security find-generic-password -s gemini -a antigravity -w`：标准错误丢掉，标准输入为空，
    /// 超时就结束子进程。启动失败返回 nil。
    public static func runSecurity(path: String = securityPath, arguments: [String] = arguments,
                                   timeout: TimeInterval = timeout) -> Outcome? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            readDone.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            _ = readDone.wait(timeout: .now() + 1)
            return Outcome(stdout: Data(), exitCode: -1, timedOut: true)
        }
        _ = readDone.wait(timeout: .now() + 1)
        return Outcome(stdout: box.data, exitCode: p.terminationStatus)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}
