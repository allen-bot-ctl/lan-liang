import Foundation

/// 一次刷新：Codex 额度、Gemini 额度各自请求，谁先回来谁先交给主线程显示，不互相等（契约 0.1.5 §5）。
/// 本机扫描（Gemini 历史）不在这里，单独在后台队列跑，额度不等它。
public enum RefreshCoordinator {
    /// - Parameters:
    ///   - codex / gemini: 各自的额度请求。
    ///   - deliver: 结果投递的队列（App 里是主队列）。
    ///   - onCodex / onGemini: 各自到了就调用。
    ///   - onAllDone: 两个都回来后调用一次（停刷新转圈用）。
    ///   - selection: 关掉的服务完全不请求、也不回调（契约 0.3.0 §1）；onAllDone 照常调用一次。
    public static func run<C, G>(codex: @escaping () async -> C, gemini: @escaping () async -> G,
                                 selection: ServiceSelection = .all,
                                 deliver: DispatchQueue = .main,
                                 onCodex: @escaping (C) -> Void, onGemini: @escaping (G) -> Void,
                                 onAllDone: @escaping () -> Void) {
        let lock = NSLock()
        var remaining = selection.enabled.count
        func finished() {
            lock.lock(); remaining -= 1; let done = remaining == 0; lock.unlock()
            if done { deliver.async { onAllDone() } }
        }
        if selection.codex {
            Task.detached(priority: .userInitiated) {
                let c = await codex()
                deliver.async { onCodex(c) }
                finished()
            }
        }
        if selection.gemini {
            Task.detached(priority: .userInitiated) {
                let g = await gemini()
                deliver.async { onGemini(g) }
                finished()
            }
        }
    }
}
