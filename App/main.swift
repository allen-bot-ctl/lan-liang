import AppKit
import SwiftUI
import Combine
import Darwin
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

/// 无边框浮层面板：悬停预览、点按固定，点别处关闭。
/// Esc（契约 0.3.15）只在面板自己收到时处理，不用全局或本地键盘监听：设置页回主页，主页收起。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 由 AppDelegate 接上：当前是不是设置页，以及执行分层判断的结果。
    var showsSettings: () -> Bool = { false }
    var onEscape: (PanelEscape.Action) -> Void = { _ in }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> PanelEscape.Modifiers {
        var m: PanelEscape.Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    /// 处理了返回 true；带修饰键的 Esc 或别的键不处理。
    @discardableResult
    func handleEscape(_ event: NSEvent?) -> Bool {
        guard let e = event, e.type == .keyDown else { return false }
        let action = PanelEscape.action(keyCode: e.keyCode, modifiers: Self.modifiers(e.modifierFlags),
                                        showsSettings: showsSettings())
        guard action != .ignore else { return false }
        onEscape(action)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if !handleEscape(NSApp.currentEvent) { super.cancelOperation(sender) }
    }

    /// SwiftUI 内容不一定把 Esc 翻译成 cancelOperation；面板自己收到的 Esc 在这里走同一条判断。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == PanelEscape.escapeKeyCode, handleEscape(event) { return }
        super.sendEvent(event)
    }
}

/// 带兜底的退出：先正常 terminate，3 秒还没退就强退。
func quitWithFallback() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    NSApp.terminate(nil)
}

#if canImport(Sparkle)
/// Sparkle 温和提醒（契约 0.2.0 §3）：定时检查找到新版本不弹窗，只在面板升级按钮上亮红点。
final class UpdateWatcher: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onResult: (String?) -> Void = { _ in }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        DispatchQueue.main.async { self.onResult(v) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.onResult(nil) }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}
#endif

/// 面板内容的圆角遮罩（圆角 10）。
func roundedMask(_ r: CGFloat) -> NSImage {
    let edge = 2 * r + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

func argValue(_ name: String) -> String? {
    CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = PanelModel()
    /// 整个 app 唯一的状态项（契约 0.1.2 §2）。
    private var statusItem: NSStatusItem!
    private var statusItemCount = 0
    private var panel: FloatingPanel?
    private var host: NSHostingView<PanelRoot>?
    private let settingsModel = SettingsModel()
    private var outsideMonitor: Any?
    private let itemHoverTracking = HoverTracking()
    private let panelHoverTracking = HoverTracking()
    private var hover = MenuPanelHover()
    private var hoverCloseTimer: Timer?
    private var hoverEnabled: Bool { !isDebug || args.contains("--debug-hover-lifecycle") || args.contains("--debug-history-lifecycle") }
    private let contextMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private var historyTimer: Timer?
    private var historyGate = GeminiHistoryWorkGate()
    private var historyCacheRequested = false
    private var historyTabObservation: AnyCancellable?
    private var historyDebugStarts = 0
    private var appearanceObservation: NSKeyValueObservation?
    private var appearanceUpdateQueued = false
    private struct StatusDisplayKey: Equatable {
        let rows: [MenuBarGroup]
        let height: CGFloat
        let palette: MenuBarLayout.Palette?
        /// 0.4.0 会话小点（空闲 = 不画）；闪烁只换图，不进这个键。
        let dot: AgentPhase
    }
    private var statusDisplayKey: StatusDisplayKey?
    private var installedMenuBarWidth = NSStatusItem.variableLength
    private var menuBarInstalls = 0
    private var menuBarRasters = 0
    private var menuBarWidthWrites = 0
    private lazy var source: DataSource = makeDataSource()
    // 0.4.0 会话状态
    private var agentWatcher: AgentWatcher?
    private var menuBarFrames: [NSImage] = []
    private var blinkIndex = 0
    private var blinkTimer: Timer?
    private var menuBarFrameSwaps = 0
    private let agentDebugRoot = NSTemporaryDirectory() + "lanliang-agent-status-\(getpid())"
    private var agentDebugFiles: (codex: String, antigravity: String)?
    private let args = CommandLine.arguments
    private var isDebug: Bool { args.contains { $0.hasPrefix("--debug-") } || ProcessInfo.processInfo.environment["LANLIANG_FAKE"] != nil }

    #if canImport(Sparkle)
    private let updateWatcher = UpdateWatcher()
    /// 没配置 Sparkle 公钥时不启动更新器，避免启动就弹错误框。
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: !((Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").isEmpty,
        updaterDelegate: updateWatcher, userDriverDelegate: updateWatcher)
    #endif

    func applicationDidFinishLaunching(_ n: Notification) {
        // 诊断：在本机实测 Gemini 历史扫描三段用时（只打印数字，不打印路径以外的任何内容），然后退出。
        if args.contains("--debug-gemini-scan-timing") {
            DispatchQueue.global(qos: .userInitiated).async {
                let x = GeminiScanTiming.run(home: FileManager.default.homeDirectoryForCurrentUser)
                for l in GeminiScanTiming.lines(x) { print(l) }
                fflush(stdout)
                exit(0)
            }
            return
        }
        if let a = argValue("debug-appearance") {
            NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
        }
        if let t = argValue("debug-tab"), let s = Service(rawValue: t) { model.tab = s }
        // 监听服务（契约 0.3.0 §1）：截图用 --debug-services 覆盖，不写盘。
        model.services = debugServices ?? ServiceSelection.load(from: .standard)
        keepTabEnabled()
        setupAgentStatus()
        if let r = argValue("debug-range"), let v = TokenRange(rawValue: r) { model.range = v }
        model.hoverKey = argValue("debug-hover")
        model.onRefresh = { [weak self] in
            guard let self else { return }
            if self.model.showsSettings { self.loadCodexModelActivity() }
            self.requestGeminiHistory(manual: true)
            self.refresh()
        }
        historyTabObservation = model.$tab.dropFirst().sink { [weak self] tab in
            // @Published sends before the property changes; inspect the selected tab
            // after the callback, and only when the panel is on screen.
            guard let self, tab == .gemini, self.model.tab != tab,
                  self.panel?.isVisible == true else { return }
            DispatchQueue.main.async { [weak self] in self?.requestGeminiHistory() }
        }
        model.appVersion = appVersion
        model.debugHistoryLoading = args.contains("--debug-loading")
        model.hoverButton = argValue("debug-hover-button")
        if let v = argValue("debug-update") { model.availableUpdate = v }
        model.onCheckUpdates = { [weak self] in self?.checkUpdatesFromPanel() }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        #if canImport(Sparkle)
        updateWatcher.onResult = { [weak self] v in self?.setAvailableUpdate(v) }
        _ = updater
        #endif

        statusItem = makeItem()
        itemHoverTracking.didEnter = { [weak self] in self?.hoverItemEntered() }
        itemHoverTracking.didLeave = { [weak self] in self?.hoverRegionLeft() }
        panelHoverTracking.didEnter = { [weak self] in self?.hoverPanelEntered() }
        panelHoverTracking.didLeave = { [weak self] in self?.hoverRegionLeft() }
        if hoverEnabled, let button = statusItem.button { itemHoverTracking.attach(to: button) }
        // 菜单栏深浅色变化（系统外观、壁纸着色）时重画，文字颜色跟着变（0.3.2）。
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            if Thread.isMainThread { self?.queueMenuBarAppearanceUpdate() }
            else { DispatchQueue.main.async { self?.queueMenuBarAppearanceUpdate() } }
        }

        loginItem.target = self
        contextMenu.delegate = self
        contextMenu.addItem(withTitle: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        contextMenu.addItem(loginItem)
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出栏量", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.addItem(quit)

        if !isDebug { enableLoginOnFirstLaunch() }
        updateMenuBar()
        loadGeminiHistoryCache()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }

        if args.contains("--debug-agent-status") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.debugAgentStatus() }
        } else if args.contains("--debug-menubar-render") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.debugMenuBarRendering() }
        } else if args.contains("--debug-history-lifecycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.debugHistoryLifecycle() }
        } else if args.contains("--debug-hover-lifecycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.debugHoverLifecycle() }
        } else if args.contains("--debug-esc-lifecycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.debugEscLifecycle() }
        } else if args.contains("--debug-settings-roundtrip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.debugSettingsRoundTrip() }
        } else if args.contains("--debug-open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.printRects() }
            }
        } else if args.contains("--debug-open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showPanel(from: self.statusItem.button)
                if let n = argValue("debug-tab-flip").flatMap({ Int($0) }), let initialFrame = self.panel?.frame {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.debugFlip(n, total: n, initialFrame: initialFrame, tops: [], bad: 0) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.printRects() }
                }
            }
        }
    }

    // MARK: 菜单栏

    /// 状态项固定的自动保存名；不用系统默认的 Item-0（旧版本留下的 Item-0 隐藏偏好会被继承，契约 0.1.3 §1）。
    static let statusItemAutosaveName = "lanliang.main"

    /// 删掉 0.1.0–0.1.2 系统自动命名留下的显示/位置偏好。
    private func clearStaleStatusItemDefaults() {
        let d = UserDefaults.standard
        for i in 0...2 {
            d.removeObject(forKey: "NSStatusItem Visible Item-\(i)")
            d.removeObject(forKey: "NSStatusItem Preferred Position Item-\(i)")
        }
    }

    private var defaultMenuBarImageScaling = NSImageScaling.scaleProportionallyDown

    private func makeItem() -> NSStatusItem {
        clearStaleStatusItemDefaults()
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.autosaveName = Self.statusItemAutosaveName
        it.isVisible = true
        statusItemCount += 1
        if let b = it.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
            defaultMenuBarImageScaling = b.imageScaling
            b.title = ""
        }
        return it
    }

    private func symbol(_ name: String, label: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        img?.isTemplate = true
        return img
    }

    /// 状态项两侧留白（点）；内容宽度见 MenuBarLayout.width。
    private let itemPadding: CGFloat = 6

    /// 只显示开着的服务（契约 0.3.0 §1）。
    private var rows: [MenuBarGroup] { MenuBarText.rows(codex: model.codex, gemini: model.gemini, selection: model.services) }

    /// Coalesce replica KVO callbacks to one semantic appearance check per run-loop turn.
    private func queueMenuBarAppearanceUpdate() {
        guard !appearanceUpdateQueued else { return }
        appearanceUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceUpdateQueued = false
            self.updateMenuBar()
        }
    }

    /// 两行保留紧凑版；只剩一行时按正常字号、原尺寸展示。
    private func updateMenuBar() {
        guard let b = statusItem.button else { return }
        let rs = rows
        let height = NSStatusBar.system.thickness
        let palette = rs.isEmpty ? nil : MenuBarLayout.Palette.resolve(b.effectiveAppearance)
        let dot: AgentPhase = rs.isEmpty ? .idle : model.visibleAgents.dot
        let key = StatusDisplayKey(rows: rs, height: height, palette: palette, dot: dot)
        guard key != statusDisplayKey else { return }

        let img: NSImage?
        let width: CGFloat
        if let palette, let raster = MenuBarLayout.image(rs, height: height, palette: palette, dot: dot) {
            img = raster
            width = ceil(raster.size.width) + itemPadding
            menuBarRasters += 1
            // 工作中慢闪：亮、暗两帧这里一起渲染好，之后每秒只换图（契约 0.4.0 §2）。
            var frames = [raster]
            if AgentDotStyle.blinks(dot), blinkAllowed,
               let dim = MenuBarLayout.image(rs, height: height, palette: palette, dot: dot,
                                             dotAlpha: CGFloat(AgentDotStyle.dimAlpha)) {
                frames.append(dim)
            }
            menuBarFrames = frames
        } else {
            menuBarFrames = []
            img = symbol("chart.bar.fill", label: "栏量")
            width = NSStatusItem.variableLength
            // A transient allocation failure may recover on a later real refresh.
            guard rs.isEmpty else { return }
        }
        // Set before AppKit writes: each write can synchronously invalidate replicas
        // and call appearance KVO again even when the visible output is unchanged.
        statusDisplayKey = key
        let scaling: NSImageScaling = rs.count == 1 ? .scaleNone : defaultMenuBarImageScaling
        if b.imageScaling != scaling { b.imageScaling = scaling }
        if installedMenuBarWidth != width {
            installedMenuBarWidth = width
            menuBarWidthWrites += 1
            statusItem.length = width
        }
        menuBarInstalls += 1
        b.image = img
        restartBlink()
    }

    /// 「减少动态效果」打开时常亮；截图（--debug-agent）停在亮帧。
    private var blinkAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && argValue("debug-agent") == nil
    }

    private func restartBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkIndex = 0
        if menuBarFrames.count == 2 { scheduleBlink() }
    }

    /// 一次性定时器链：每 1 秒切一帧，只换图，不重排版、不改宽度。
    private func scheduleBlink() {
        let t = Timer(timeInterval: AgentDotStyle.blinkInterval, repeats: false) { [weak self] _ in
            guard let self, self.menuBarFrames.count == 2, let b = self.statusItem.button else { return }
            self.blinkIndex = 1 - self.blinkIndex
            b.image = self.menuBarFrames[self.blinkIndex]
            self.menuBarFrameSwaps += 1
            self.scheduleBlink()
        }
        blinkTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: 会话状态（契约 0.4.0）

    private func setupAgentStatus() {
        if let d = argValue("debug-agent") {
            // 截图：固定状态，不监听任何目录。
            model.agents = AgentSnapshot.parseDebug(d, now: source.fixedNow ?? Date())
            return
        }
        let roots: AgentWatcher.Roots
        if args.contains("--debug-agent-status") {
            agentDebugFiles = prepareAgentDebugRoot()
            roots = AgentWatcher.roots(under: agentDebugRoot)
        } else if let r = ProcessInfo.processInfo.environment["LANLIANG_AGENT_ROOT"], !r.isEmpty {
            roots = AgentWatcher.roots(under: r)
        } else if isDebug {
            return  // 截图 / CI 不读本机会话
        } else {
            roots = AgentWatcher.defaultRoots()
        }
        let w = AgentWatcher(roots: roots)
        w.keepsEventLog = args.contains("--debug-agent-status")
        w.onChange = { [weak self] snap in
            guard let self else { return }
            self.model.agents = snap
            self.updateMenuBar()
        }
        agentWatcher = w
        updateAgentWatch()
    }

    /// 跟随「监听服务」；随额度刷新顺带看一次目录有没有出现。
    private func updateAgentWatch() {
        agentWatcher?.update(codex: model.services.codex, antigravity: model.services.gemini)
    }

    private func prepareAgentDebugRoot() -> (codex: String, antigravity: String) {
        let fm = FileManager.default
        let r = AgentWatcher.roots(under: agentDebugRoot)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = r.codex + String(format: "/%04d/%02d/%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
        try? fm.createDirectory(atPath: day, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: r.antigravity + "/debug-session", withIntermediateDirectories: true)
        return (day + "/rollout-debug.jsonl", r.antigravity + "/debug-session/transcript.jsonl")
    }

    private func appendLine(_ line: String, to path: String) {
        let data = Data((line + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// CI：往假目录依次追加事件，断言状态序列；工作中闪烁期间只换图、不重渲染、不改宽度。
    private func debugAgentStatus() {
        guard let files = agentDebugFiles, let w = agentWatcher else {
            print("DEBUG_AGENT_STATUS failed: no watcher"); fflush(stdout); return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func codex(_ type: String, _ payload: String) -> String {
            "{\"timestamp\":\"\(iso.string(from: Date()))\",\"type\":\"\(type)\",\"payload\":\(payload)}"
        }
        /// 0.4.1：Antigravity 一行记录；tools = nil 不写 tool_calls（最终回复）。
        func ag(_ type: String, source: String = "MODEL", status: String = "DONE", tools: Bool = false) -> String {
            "{\"type\":\"\(type)\",\"status\":\"\(status)\",\"source\":\"\(source)\",\"created_at\":\"\(iso.string(from: Date()))\",\"step_index\":1" +
                (tools ? ",\"tool_calls\":[{\"name\":\"DEBUG_SECRET_MARKER\"}]" : "") + ",\"content\":\"DEBUG_SECRET_MARKER\"}"
        }
        // 契约 0.4.1 §C：真实序列 fixture（老板 Mac step 20–49，只有字段名）；CI 用 --debug-agent-fixture 传路径。
        let real: [(step: Int, line: String)] = (argValue("debug-agent-fixture")
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
            .split(separator: "\n").compactMap { l in
                guard let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
                      let step = o["step_index"] as? Int else { return nil }
                return (step, String(l))
            }
        guard real.count >= 30 else {
            print("DEBUG_AGENT_STATUS failed: no fixture"); fflush(stdout); exit(1)
        }
        func realSteps(_ r: ClosedRange<Int>) { for x in real where r.contains(x.step) { self.appendLine(x.line, to: files.antigravity) } }
        typealias Expect = (AgentPhase, AgentPhase)
        struct Step { let name: String; let write: () -> Void; let expect: Expect; let settle: Bool }
        let cf = files.codex, af = files.antigravity
        let steps: [Step] = [
            Step(name: "task_started", write: {
                self.appendLine(codex("session_meta", "{\"id\":\"debug\"}"), to: cf)
                self.appendLine(codex("event_msg", "{\"type\":\"task_started\"}"), to: cf)
            }, expect: (.working, .idle), settle: false),
            Step(name: "ask", write: {
                self.appendLine(codex("response_item", "{\"type\":\"function_call\",\"name\":\"request_user_input_async\",\"arguments\":\"{\\\"q\\\":\\\"DEBUG_SECRET_MARKER\\\"}\",\"call_id\":\"call_dbg_1\"}"), to: cf)
            }, expect: (.asking, .idle), settle: false),
            Step(name: "ask_output", write: {
                self.appendLine(codex("response_item", "{\"type\":\"function_call_output\",\"call_id\":\"call_dbg_1\",\"output\":\"DEBUG_SECRET_MARKER\"}"), to: cf)
            }, expect: (.working, .idle), settle: false),
            Step(name: "task_complete", write: {
                self.appendLine(codex("event_msg", "{\"type\":\"task_complete\"}"), to: cf)
            }, expect: (.done, .idle), settle: false),
            Step(name: "turn_aborted", write: {
                self.appendLine(codex("event_msg", "{\"type\":\"turn_aborted\"}"), to: cf)
            }, expect: (.failed, .idle), settle: false),
            Step(name: "ag_step20_31", write: { realSteps(20...31) }, expect: (.failed, .working), settle: true),
            Step(name: "ag_step32_final", write: { realSteps(32...32) }, expect: (.failed, .done), settle: false),
            Step(name: "ag_step33_user_input", write: { realSteps(33...33) }, expect: (.failed, .working), settle: false),
            Step(name: "ag_step34_49", write: { realSteps(34...49) }, expect: (.failed, .working), settle: true),
            Step(name: "ag_final", write: { self.appendLine(ag("PLANNER_RESPONSE"), to: af) }, expect: (.failed, .done), settle: false),
            Step(name: "ag_system_message", write: { self.appendLine(ag("SYSTEM_MESSAGE", source: "SYSTEM"), to: af) }, expect: (.failed, .working), settle: false),
            Step(name: "ag_error_message", write: { self.appendLine(ag("ERROR_MESSAGE", source: "SYSTEM"), to: af) }, expect: (.failed, .failed), settle: false),
            Step(name: "bad_lines", write: {
                self.appendLine("{not json", to: cf)
                self.appendLine("\"just a string\"", to: af)
                self.appendLine("{\"status\":42}", to: af)
            }, expect: (.failed, .failed), settle: true),
            Step(name: "unknown", write: {
                self.appendLine(codex("event_msg", "{\"type\":\"some_future_event\"}"), to: cf)
                self.appendLine(codex("response_item", "{\"type\":\"function_call\",\"name\":\"shell\",\"call_id\":\"call_x\"}"), to: cf)
                self.appendLine("{\"status\":\"SOMETHING_NEW\",\"source\":\"MODEL\"}", to: af)
            }, expect: (.failed, .failed), settle: true),
        ]
        var seq: [String] = []
        var blink = "skipped"
        var widthsAfterFirst = -1
        func phases() -> Expect { (model.agents.codex?.phase ?? .idle, model.agents.antigravity?.phase ?? .idle) }
        func finish(_ ok: Bool, _ why: String) {
            let log = (w.eventLog(.codex) + w.eventLog(.antigravity))
            let leak = log.contains { $0.contains("DEBUG_SECRET_MARKER") || $0.contains("debug-session") }
            let good = ok && !leak
            let widths = widthsAfterFirst < 0 ? -1 : menuBarWidthWrites - widthsAfterFirst
            print("DEBUG_AGENT_STATUS \(good ? "ok" : "failed") \(why) seq=\(seq.joined(separator: ",")) blink=\(blink) widths=\(widths) events=\(log.joined(separator: ",")) reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
            fflush(stdout)
            // 契约 0.4.1 §C：打印结果后自己退出，ok = 0，failed = 1。
            exit(good ? 0 : 1)
        }
        func run(_ i: Int) {
            guard i < steps.count else {
                let widths = menuBarWidthWrites - widthsAfterFirst
                finish(widths == 0, "steps=\(steps.count)")
                return
            }
            let st = steps[i]
            st.write()
            var waited = 0.0
            func poll() {
                let p = phases()
                let match = p == st.expect
                if (st.settle && waited >= 2.5) || (!st.settle && match) {
                    guard match else {
                        finish(false, "at=\(st.name) codex=\(p.0.debugName) antigravity=\(p.1.debugName)")
                        return
                    }
                    seq.append("\(st.name)=\(p.0.debugName)/\(p.1.debugName)")
                    if i == 0 { widthsAfterFirst = menuBarWidthWrites }
                    if st.name == "ask" && menuBarFrames.count != 1 {
                        finish(false, "at=ask frames=\(menuBarFrames.count)"); return
                    }
                    if st.name == "ask_output" {
                        // 工作中闪烁 3 秒：只换图。
                        let counts = (menuBarRasters, menuBarInstalls, menuBarWidthWrites, menuBarFrameSwaps)
                        let frames = menuBarFrames
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
                            let swaps = self.menuBarFrameSwaps - counts.3
                            let rasters = self.menuBarRasters - counts.0
                            let installs = self.menuBarInstalls - counts.1
                            let widths = self.menuBarWidthWrites - counts.2
                            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                            let sameFrames = frames.count == self.menuBarFrames.count && zip(frames, self.menuBarFrames).allSatisfy { $0 === $1 }
                            let shown = self.statusItem.button?.image
                            let showsFrame = frames.contains { $0 === shown }
                            blink = "swaps=\(swaps),rasters=\(rasters),installs=\(installs),widths=\(widths),frames=\(frames.count)"
                            let ok = rasters == 0 && installs == 0 && widths == 0 && sameFrames && showsFrame &&
                                (reduce ? swaps == 0 : (frames.count == 2 && swaps >= 2 && swaps <= 4))
                            guard ok else { finish(false, "at=blink"); return }
                            run(i + 1)
                        }
                        return
                    }
                    run(i + 1)
                    return
                }
                if waited >= 8 {
                    finish(false, "at=\(st.name) timeout codex=\(p.0.debugName) antigravity=\(p.1.debugName)")
                    return
                }
                waited += 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        run(0)
    }

    @objc private func clicked(_ sender: NSButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            contextMenuWillOpen()
            statusItem.menu = contextMenu
            sender.performClick(nil)
            statusItem.menu = nil
            hover.endMenu()
            return
        }
        clickPin(from: sender)
    }

    /// 点图标：固定或收起。固定时面板成为键盘焦点，Esc 直接生效；悬停预览不抢焦点。
    private func clickPin(from sender: NSButton?) {
        cancelHoverClose()
        hover.click()
        if hover.mode == .hidden { hidePanel() }
        else {
            openMenuPanel(from: sender)
            if hover.mode == .pinned, panel?.isVisible == true {
                panel?.makeKey()
                requestGeminiHistory()
                refresh()
            }
        }
    }

    private func panelEscape(_ action: PanelEscape.Action) {
        switch action {
        case .returnToMain: model.returnToDashboard()
        case .closePanel: hidePanel()
        case .ignore: break
        }
    }

    private func openMenuPanel(from sender: NSButton?) {
        guard panel?.isVisible != true else { return }
        // 默认停在上次的页签；当前页签那家没登录、另一家登录了，就切过去。
        keepTabEnabled()
        let shown = Set(rows.map { $0.service })
        if !shown.contains(model.tab), let other = shown.first { model.tab = other }
        showPanel(from: sender)
        guard panel?.isVisible == true else { hover.hide(); return }
    }

    private func hoverItemEntered() {
        cancelHoverClose()
        hover.enterItem()
        if hover.mode == .preview { openMenuPanel(from: statusItem.button) }
    }

    private func hoverPanelEntered() {
        cancelHoverClose()
        hover.enterPanel()
    }

    private func hoverRegionLeft() {
        cancelHoverClose()
        hover.leave(now: ProcessInfo.processInfo.systemUptime)
        guard hover.deadline != nil else { return }
        let timer = Timer(timeInterval: MenuPanelHover.grace + 0.01, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.finishHoverClose(pointerInside: self.pointerInsideMenuPanel())
        }
        hoverCloseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishHoverClose(pointerInside: Bool) {
        let wasPreview = hover.mode == .preview
        hover.tick(now: ProcessInfo.processInfo.systemUptime, pointerInside: pointerInside)
        if wasPreview, hover.mode == .hidden { hidePanel() }
    }

    private func cancelHoverClose() {
        hoverCloseTimer?.invalidate()
        hoverCloseTimer = nil
    }

    private func pointerInsideMenuPanel() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let button = statusItem.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(mouse) { return true }
        return panel?.isVisible == true && panel?.frame.contains(mouse) == true
    }

    private func contextMenuWillOpen() {
        hidePanel()
        hover.beginMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === contextMenu { contextMenuWillOpen() }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === contextMenu { hover.endMenu() }
    }

    // MARK: 面板

    /// 面板第一次打开时才创建（SwiftUI/Charts 不在启动时渲染）。
    private func ensurePanel() {
        guard panel == nil else { return }
        let h = NSHostingView(rootView: PanelRoot(model: model, settings: settingsModel))
        // 面板尺寸只由 showPanel 设置，内容变化由 SwiftUI 的滚动区吸收。
        h.sizingOptions = []
        let frame = NSRect(origin: .zero, size: Self.mainPanelSize)
        let p = FloatingPanel(contentRect: frame,
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        // 半透明圆角（契约 0.2.0 §2）：内容放在 .popover 材质里，圆角 10。
        let fx = NSVisualEffectView(frame: frame)
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = roundedMask(10)
        h.frame = fx.bounds
        h.autoresizingMask = [.width, .height]
        fx.addSubview(h)
        if hoverEnabled { panelHoverTracking.attach(to: fx) }
        p.contentView = fx
        p.showsSettings = { [weak self] in self?.model.showsSettings ?? false }
        p.onEscape = { [weak self] action in self?.panelEscape(action) }
        host = h
        panel = p
    }

    private func showPanel(from button: NSButton?) {
        ensurePanel()
        guard let button = button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let panel = panel else { return }
        let screen = win.screen ?? NSScreen.main
        let top = r.minY - 4
        let size = panelSize(availableHeight: screen.map { top - $0.visibleFrame.minY - 8 })
        var x = r.minX
        if let screen {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        model.panelVisible = panel.isVisible
        panel.invalidateShadow()
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    private func hidePanel() {
        cancelHoverClose()
        hover.hide()
        panel?.orderOut(nil)
        model.panelVisible = false
        historyTimer?.invalidate()
        historyTimer = nil
        historyGate.cancelPending()
        model.showsSettings = false
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    /// 对齐较矮的 Codex 面板；只有屏幕放不下时才缩小滚动视口。
    private static let mainPanelSize = NSSize(width: 400, height: 414)

    private func panelSize(availableHeight: CGFloat?) -> NSSize {
        var height = Self.mainPanelSize.height
        if let availableHeight { height = min(height, max(1, floor(availableHeight))) }
        if let value = argValue("debug-max-height").flatMap({ Double($0) }), value.isFinite, value >= 1 {
            height = min(height, floor(CGFloat(value)))
        }
        return NSSize(width: Self.mainPanelSize.width, height: height)
    }

    /// Hosted smoke: drive the same AppKit tracking callbacks with a fixture, without moving the host mouse.
    private func debugHoverLifecycle() {
        guard let button = statusItem.button else { return }
        func send(_ type: NSEvent.EventType, _ tracker: HoverTracking) {
            guard let event = NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: button.window?.windowNumber ?? 0,
                                                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
            else { return }
            if type == .mouseEntered { tracker.mouseEntered(with: event) }
            else { tracker.mouseExited(with: event) }
        }
        send(.mouseEntered, itemHoverTracking)
        let preview = panel?.isVisible == true && hover.mode == .preview
        send(.mouseExited, itemHoverTracking)
        let grace = hover.deadline != nil
        send(.mouseEntered, panelHoverTracking)
        let crossed = panel?.isVisible == true && hover.deadline == nil
        clicked(button)
        let pinned = panel?.isVisible == true && hover.mode == .pinned
        send(.mouseExited, panelHoverTracking)
        let held = hover.deadline == nil
        contextMenuWillOpen()
        send(.mouseEntered, itemHoverTracking)
        let menuSafe = panel?.isVisible == false && hover.menuOpen
        hover.endMenu()
        send(.mouseEntered, itemHoverTracking)
        send(.mouseExited, panelHoverTracking)
        cancelHoverClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuPanelHover.grace + 0.03) { [weak self] in
            guard let self else { return }
            self.finishHoverClose(pointerInside: false)
            let dismissed = self.panel?.isVisible == false
            let ok = preview && grace && crossed && pinned && held && menuSafe && dismissed
            print("DEBUG_HOVER_LIFECYCLE \(ok ? "ok" : "failed") preview=\(preview) grace=\(grace) crossed=\(crossed) pinned=\(pinned) held=\(held) menu=\(menuSafe) dismissed=\(dismissed)")
            fflush(stdout)
        }
    }

    /// Native fixture against the real NSStatusItem and fake stable quota. Measures
    /// process user+system CPU, independent of how often host AppKit asks to draw.
    private func debugMenuBarRendering() {
        guard let button = statusItem.button, let before = statusDisplayKey,
              let palette = before.palette, let original = button.image else {
            print("DEBUG_MENUBAR_RENDER failed: no rendered fixture")
            fflush(stdout)
            return
        }
        func clock() -> (wall: Double, cpu: Double) {
            var t = timespec()
            let result = clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
            let cpu = result == 0 ? Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 : -1
            return (ProcessInfo.processInfo.systemUptime, cpu)
        }
        func concrete(_ image: NSImage?, pixels: CGSize) -> Bool {
            let reps = image?.representations ?? []
            return reps.count == 2 && reps.allSatisfy { $0 is NSBitmapImageRep } &&
                reps.map(\.pixelsWide).sorted() == [Int(ceil(pixels.width)), Int(ceil(pixels.width * 2))] &&
                reps.map(\.pixelsHigh).sorted() == [Int(ceil(pixels.height)), Int(ceil(pixels.height * 2))]
        }
        func repeatRefresh(_ remaining: Int, completion: @escaping () -> Void) {
            guard remaining > 0 else { completion(); return }
            refresh()
            // Exercise both identical quota callbacks and duplicate appearance signals.
            for _ in 0..<4 { queueMenuBarAppearanceUpdate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { repeatRefresh(remaining - 1, completion: completion) }
        }
        let counts = (menuBarRasters, menuBarInstalls, menuBarWidthWrites)
        let initialConcrete = concrete(original, pixels: original.size)
        let t0 = clock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            let t1 = clock()
            let idleStable = counts == (self.menuBarRasters, self.menuBarInstalls, self.menuBarWidthWrites) && button.image === original
            repeatRefresh(80) {
                let t2 = clock()
                let burstStable = counts == (self.menuBarRasters, self.menuBarInstalls, self.menuBarWidthWrites) && button.image === original
                // Change the actual view appearance. Its KVO and explicit duplicate
                // signals must collapse to one new image and no layout write.
                button.appearance = NSAppearance(named: palette.dark ? .aqua : .darkAqua)
                for _ in 0..<20 { self.queueMenuBarAppearanceUpdate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    let appearanceChanged = self.statusDisplayKey?.palette?.dark == !palette.dark
                    let rasterDelta = self.menuBarRasters - counts.0
                    let installDelta = self.menuBarInstalls - counts.1
                    let widthDelta = self.menuBarWidthWrites - counts.2
                    let idle = (t1.cpu - t0.cpu) / (t1.wall - t0.wall) * 100
                    let burst = (t2.cpu - t1.cpu) / (t2.wall - t1.wall) * 100
                    let ok = initialConcrete && idleStable && burstStable && appearanceChanged &&
                        rasterDelta == 1 && installDelta == 1 && widthDelta == 0 &&
                        button.image !== original && concrete(button.image, pixels: original.size) &&
                        t0.cpu >= 0 && t1.cpu >= 0 && t2.cpu >= 0 && idle < 35 && burst < 55
                    let idleText = String(format: "%.2f", idle)
                    let burstText = String(format: "%.2f", burst)
                    let idleCoreSeconds = String(format: "%.4f", t1.cpu - t0.cpu)
                    let burstCoreSeconds = String(format: "%.4f", t2.cpu - t1.cpu)
                    let idleWallSeconds = String(format: "%.3f", t1.wall - t0.wall)
                    let burstWallSeconds = String(format: "%.3f", t2.wall - t1.wall)
                    print("DEBUG_MENUBAR_RENDER \(ok ? "ok" : "failed") rows=\(before.rows.count) bitmap=\(initialConcrete) idleStable=\(idleStable) burstStable=\(burstStable) appearance=\(appearanceChanged) rasters=\(rasterDelta) installs=\(installDelta) widths=\(widthDelta) idleCPU=\(idleText)% burstCPU=\(burstText)% idleCoreSeconds=\(idleCoreSeconds) idleWallSeconds=\(idleWallSeconds) burstCoreSeconds=\(burstCoreSeconds) burstWallSeconds=\(burstWallSeconds) agentWatch=\(self.agentWatcher?.isWatching == true)")
                    fflush(stdout)
                }
            }
        }
    }

    /// Native acceptance fixture: run the same startup/hover/timer refresh routes,
    /// then pin and manually refresh. Only explicit, visible demand starts a scan.
    private func debugHistoryLifecycle() {
        guard let button = statusItem.button, model.shownTab == .gemini else {
            print("DEBUG_HISTORY_LIFECYCLE failed: fixture must start on Gemini")
            fflush(stdout)
            return
        }
        let startup = historyDebugStarts
        timer?.fire()
        hoverItemEntered()
        let preview = panel?.isVisible == true && hover.mode == .preview
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let automatic = self.historyDebugStarts
            self.clicked(button)
            let pinned = self.panel?.isVisible == true && self.hover.mode == .pinned
            self.model.onRefresh()
            self.model.onRefresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let foreground = self.historyDebugStarts
                self.hidePanel()
                self.timer?.fire()
                self.model.onRefresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let hidden = self.historyDebugStarts
                    let ok = startup == 0 && automatic == 0 && foreground == 1 && hidden == 1 && preview && pinned
                    print("DEBUG_HISTORY_LIFECYCLE \(ok ? "ok" : "failed") startup=\(startup) automatic=\(automatic) foreground=\(foreground) hidden=\(hidden) preview=\(preview) pinned=\(pinned)")
                    fflush(stdout)
                }
            }
        }
    }

    /// CI（契约 0.3.15）：悬停预览不抢焦点；点图标固定、进设置、⌘Esc 不处理、Esc 回主页、Esc 收起、再点图标停在主页。
    /// Esc 用合成的按键事件送进面板，走和真实按键一样的 FloatingPanel.sendEvent / cancelOperation。
    private func debugEscLifecycle() {
        func key(_ p: NSPanel, _ flags: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.windowNumber,
                                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: PanelEscape.escapeKeyCode) {
                p.sendEvent(e)
            }
        }
        func after(_ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: body) }
        hover.enterItem()
        if hover.mode == .preview { openMenuPanel(from: statusItem.button) }
        after {
            let previewNoKey = self.panel?.isVisible == true && self.hover.mode == .preview && self.panel?.isKeyWindow == false
            self.clickPin(from: self.statusItem.button)
            after {
                guard let p = self.panel else { print("DEBUG_ESC_LIFECYCLE failed: no panel"); fflush(stdout); return }
                let pinned = p.isVisible && self.hover.mode == .pinned && !self.model.showsSettings
                let pinnedKey = p.isKeyWindow
                self.model.onOpenSettings()
                after {
                    let settings = p.isVisible && self.model.showsSettings
                    key(p, .command)
                    let modifierIgnored = p.isVisible && self.model.showsSettings
                    key(p)
                    after {
                        let backToMain = p.isVisible && !self.model.showsSettings
                        self.printRects()
                        key(p)
                        after {
                            let closed = !p.isVisible && !self.model.panelVisible
                            self.clickPin(from: self.statusItem.button)
                            after {
                                let reopenedMain = p.isVisible && !self.model.showsSettings && self.hover.mode == .pinned
                                let reopenedKey = p.isKeyWindow
                                let ok = previewNoKey && pinned && pinnedKey && settings && modifierIgnored
                                    && backToMain && closed && reopenedMain && reopenedKey
                                print("DEBUG_ESC_LIFECYCLE \(ok ? "ok" : "failed") previewNoKey=\(previewNoKey) pinned=\(pinned) pinnedKey=\(pinnedKey) settings=\(settings) modifierIgnored=\(modifierIgnored) backToMain=\(backToMain) closed=\(closed) reopenedMain=\(reopenedMain) reopenedKey=\(reopenedKey)")
                                fflush(stdout)
                            }
                        }
                    }
                }
            }
        }
    }

    /// CI：使用齿轮与返回共用的动作，核对服务开关、窗口标识和位置。
    private func debugSettingsRoundTrip() {
        showPanel(from: statusItem.button)
        guard let p = panel, let initialHost = host, p.isVisible, debugServices != nil else {
            print("DEBUG_SETTINGS_ROUNDTRIP failed: missing panel or isolated service preferences")
            return
        }
        let frame = p.frame
        let number = p.windowNumber
        let tab = model.shownTab
        let visibleWindows = Set(NSApp.windows.filter { $0.isVisible }.map { $0.windowNumber })
        model.onOpenSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let entered = self.model.showsSettings && self.panel === p && self.host === initialHost
                && p.windowNumber == number && p.frame == frame && p.isVisible
                && Set(NSApp.windows.filter { $0.isVisible }.map { $0.windowNumber }) == visibleWindows
            let other: Service = tab == .codex ? .gemini : .codex
            self.settingsModel.setService(other, false)
            let toggled = !self.model.services.isOn(other) && self.model.shownTab == tab
            self.settingsModel.setService(tab, false)
            let protectsLast = self.model.services.isOn(tab)
            self.settingsModel.setService(other, true)
            self.model.returnToDashboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let returned = !self.model.showsSettings && self.panel === p && self.host === initialHost
                    && p.windowNumber == number && p.frame == frame && p.isVisible && self.model.shownTab == tab
                    && self.model.services.isOn(other)
                    && Set(NSApp.windows.filter { $0.isVisible }.map { $0.windowNumber }) == visibleWindows
                self.model.onOpenSettings()
                self.hidePanel()
                self.showPanel(from: self.statusItem.button)
                let reopened = !self.model.showsSettings && self.panel === p && p.frame == frame && p.isVisible
                let ok = entered && toggled && protectsLast && returned && reopened
                print("DEBUG_SETTINGS_ROUNDTRIP \(ok ? "ok" : "failed") tab=\(tab.rawValue) entered=\(entered) toggled=\(toggled) lastProtected=\(protectsLast) returned=\(returned) reopened=\(reopened)")
                self.printRects()
                fflush(stdout)
            }
        }
    }

    /// 截图用：来回切页签 n 次，每次检查面板顶边、内容视图和窗口是否一致，最后打印截图区域。
    private func debugFlip(_ left: Int, total: Int, initialFrame: NSRect, tops: [CGFloat], bad: Int) {
        // 只开一个服务时没有页签可切（契约 0.3.0 §2）：不切，直接打印截图区域。
        if model.services.isSingle {
            print("DEBUG_TABFLIP skipped services=\(model.services.debugText)")
            printRects()
            return
        }
        if left == 0 {
            let t = tops.map { Int($0.rounded()) }
            print("DEBUG_TABFLIP flips=\(total) tab=\(model.tab.rawValue) topsUnique=\(Set(t).count) top=\(t.first ?? 0) mismatches=\(bad)")
            printRects()
            return
        }
        model.tab = model.tab == .codex ? .gemini : .codex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let p = self.panel, let h = self.host, let cv = p.contentView else { return }
            let ok = abs(h.frame.height - cv.bounds.height) < 0.5 && abs(h.frame.maxY - cv.bounds.maxY) < 0.5
                && p.frame == initialFrame
            self.debugFlip(left - 1, total: total, initialFrame: initialFrame, tops: tops + [p.frame.maxY], bad: bad + (ok ? 0 : 1))
        }
    }

    // MARK: 刷新

    private func refresh() {
        guard !model.refreshing else {
            // 刷新途中重新打开了某个服务：这轮结束后再刷一次（契约 0.3.0 §1「重新打开时立即刷新一次」）。
            if pendingRefresh { refreshAgain = true }
            pendingRefresh = false
            return
        }
        pendingRefresh = false
        updateAgentWatch()
        model.refreshing = true
        if let now = source.fixedNow { model.now = { now } }
        let selection = model.services
        // 两家额度各自到了就各自更新菜单栏和面板（契约 0.1.5 §5）；关掉的服务不请求（契约 0.3.0 §1）。
        source.refresh(current: (model.codex, model.gemini), selection: selection, handlers: RefreshHandlers(
            onCodex: { [weak self] s in
                guard let self = self else { return }
                self.model.codex = s
                self.updateMenuBar()
            },
            onCodexOfficial: { [weak self] o in
                guard self?.args.contains("--debug-loading") == false else { return }
                self?.model.official = o
                self?.model.officialLoaded = true
            },
            onGemini: { [weak self] s in
                guard let self = self else { return }
                self.model.gemini = s
                self.updateMenuBar()
            },
            onAllDone: { [weak self] in
                guard let self = self else { return }
                // 截图用：--debug-loading 停在加载态（转圈、「正在统计…」）。
                if self.args.contains("--debug-loading") { return }
                self.model.refreshing = false
                self.model.lastUpdated = Date()
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }))
    }

    private func loadGeminiHistoryCache() {
        guard model.services.gemini, !historyCacheRequested, !args.contains("--debug-loading") else { return }
        historyCacheRequested = true
        source.loadCachedGeminiHistory { [weak self] history in
            guard let self, self.model.geminiHistory == nil else { return }
            self.model.geminiHistory = history
        }
    }

    private var geminiHistoryIsVisible: Bool {
        panel?.isVisible == true && model.services.gemini && (model.showsSettings || model.shownTab == .gemini)
    }

    /// Called only for deliberate foreground actions. Hover previews, startup, quota
    /// reconnects and the five-minute timer never open a conversation DB.
    private func requestGeminiHistory(manual: Bool = false) {
        guard geminiHistoryIsVisible, !args.contains("--debug-loading"),
              historyGate.request(now: ProcessInfo.processInfo.systemUptime, manual: manual) else { return }
        let timer = Timer(timeInterval: GeminiHistoryWorkGate.debounce + 0.01, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.historyTimer = nil
            guard self.historyGate.start(now: ProcessInfo.processInfo.systemUptime,
                                         visible: self.geminiHistoryIsVisible) else { return }
            if self.args.contains("--debug-history-lifecycle") { self.historyDebugStarts += 1 }
            self.model.historyScanning = true
            self.source.refreshGeminiHistory { [weak self] history in
                guard let self else { return }
                self.historyGate.finish()
                self.model.geminiHistory = history
                self.model.historyScanning = false
            }
        }
        historyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: 监听服务（契约 0.3.0 §1）

    private var debugServices: ServiceSelection? { argValue("debug-services").flatMap { ServiceSelection.parse($0) } }
    /// 下一次 refresh() 是「重新打开服务」触发的。
    private var pendingRefresh = false
    /// 当前这轮刷新结束后再刷一次。
    private var refreshAgain = false

    /// 当前页签必须是开着的服务。
    private func keepTabEnabled() {
        if !model.services.isOn(model.tab), let first = model.services.enabled.first { model.tab = first }
    }

    /// 设置窗口里拨开关：最后一个开着的服务拨不动，偏好不变。
    private func setService(_ s: Service, on: Bool) {
        let old = model.services
        let new = old.setting(s, on: on)
        guard new != old else { return }
        model.services = new
        if debugServices == nil { new.save(to: .standard) }
        keepTabEnabled()
        updateAgentWatch()
        updateMenuBar()
        if on {
            loadGeminiHistoryCache()
            if s == .gemini { requestGeminiHistory() }
            if s == .codex && model.showsSettings { loadCodexModelActivity() }
            pendingRefresh = true
            refresh()
        }
    }

    // MARK: 登录时启动

    private func enableLoginOnFirstLaunch() {
        let key = "didAutoEnableLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        settingsModel.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @objc private func checkUpdates() {
        #if canImport(Sparkle)
        updater.checkForUpdates(nil)
        #endif
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    private func setAvailableUpdate(_ v: String?) {
        model.availableUpdate = v
        settingsModel.availableUpdate = v
    }

    /// 面板在 statusBar 层级，先收起面板、激活 App，再弹 Sparkle（契约 0.2.0 §3）。
    private func checkUpdatesFromPanel() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        checkUpdates()
    }

    // MARK: 面板内设置

    private func openSettings() {
        settingsModel.version = appVersion
        settingsModel.availableUpdate = model.availableUpdate
        settingsModel.launchAtLogin = SMAppService.mainApp.status == .enabled
        #if canImport(Sparkle)
        settingsModel.autoCheck = updater.updater.automaticallyChecksForUpdates
        #endif
        settingsModel.setLaunchAtLogin = { [weak self] on in self?.setLogin(on) }
        settingsModel.setAutoCheck = { [weak self] on in
            #if canImport(Sparkle)
            self?.updater.updater.automaticallyChecksForUpdates = on
            #endif
        }
        settingsModel.onCheckUpdates = { [weak self] in self?.checkUpdatesFromPanel() }
        settingsModel.onQuit = { quitWithFallback() }
        settingsModel.setService = { [weak self] s, on in self?.setService(s, on: on) }
        if panel?.isVisible != true { showPanel(from: statusItem.button) }
        guard panel?.isVisible == true else { return }
        model.showsSettings = true
        cancelHoverClose()
        hover.pin() // Settings/export should survive pointer departure.
        panel?.makeKey()
        loadCodexModelActivity()
        requestGeminiHistory()
    }

    private func loadCodexModelActivity() {
        guard model.services.codex else { return }
        source.loadCodexModels(now: model.now()) { [weak self] data in
            self?.model.codexModelActivity = data
            self?.model.loadedCodexModelActivity = true
        }
    }

    private func setLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        settingsModel.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @objc private func quit() { quitWithFallback() }

    // MARK: 调试输出（CI 截图）

    /// 打印截图区域（左上原点、单位点），供 scripts/ci_screenshots.sh 用 screencapture -R 裁剪。
    private func printRects() {
        guard let screen = NSScreen.screens.first else { return }
        let h = screen.frame.height
        func top(_ r: NSRect) -> String { "\(Int(r.minX)),\(Int(h - r.maxY)),\(Int(r.width)),\(Int(r.height))" }
        let mbh = NSStatusBar.system.thickness
        print("DEBUG_RECT_MENUBAR \(top(NSRect(x: 0, y: h - mbh, width: screen.frame.width, height: mbh)))")
        var itemWidth = 0.0
        if let b = statusItem.button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            itemWidth = r.width
            print("DEBUG_RECT_ITEM \(top(r))")
        }
        if let p = panel { print("DEBUG_RECT_PANEL \(top(p.frame))") }
        let rs = rows
        let groups = rs.map { "\($0.service.rawValue):\($0.primary)\($0.secondary.map { "+" + $0 } ?? "")" }
        let content = String(format: "%.1f", MenuBarLayout.width(rs))
        let style = rs.count >= 2 ? "compact" : "single"
        if let button = statusItem.button, let image = button.image {
            let font = MenuBarLayout.style(rowCount: rs.count).primaryFont.pointSize
            let scale = button.window?.backingScaleFactor ?? 1
            print("DEBUG_MENUBAR_RENDER font=\(font) scale=\(scale) noResize=\(button.imageScaling == .scaleNone ? 1 : 0) image=\(image.size.width)x\(image.size.height)")
        }
        let cells = rs.map { "\($0.service.rawValue):\(MenuBarLayout.cellText($0))" }.joined(separator: ",")
        let dark = (statusItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ? 1 : 0
        print("DEBUG_MENUBAR_WIDTH content=\(content) item=\(Int(itemWidth)) style=\(rs.count >= 2 ? "compact" : "single")")
        print("DEBUG_MENUBAR_CELLS cells=\(cells.isEmpty ? "fallback" : cells) dark=\(dark) template=\(statusItem.button?.image?.isTemplate == true ? 1 : 0)")
        print("DEBUG_MENUBAR items=\(statusItemCount) visible=\(statusItem.isVisible ? 1 : 0) autosave=\(statusItem.autosaveName ?? "") rows=\(rs.count) content=\(content) item=\(Int(itemWidth)) groups=\(groups.isEmpty ? "fallback" : groups.joined(separator: ",")) services=\(model.services.debugText) style=\(style) agent=\(model.visibleAgents.dot.debugName) agents=\(model.visibleAgents.debugText)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
