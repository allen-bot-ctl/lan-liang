import AppKit
import SwiftUI
import ServiceManagement
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// 无边框浮层面板：点菜单栏项打开，点别处关闭。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    private var host: NSHostingView<PanelView>?
    /// 只用来量面板自然高度（不进窗口）。
    private var measurer: NSHostingController<PanelView>?
    private var settingsWindow: NSWindow?
    private let settingsModel = SettingsModel()
    private var outsideMonitor: Any?
    private let contextMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private var subs: Set<AnyCancellable> = []
    private lazy var source: DataSource = makeDataSource()
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
        if let r = argValue("debug-range"), let v = TokenRange(rawValue: r) { model.range = v }
        model.hoverKey = argValue("debug-hover")
        model.onRefresh = { [weak self] in self?.refresh() }
        model.appVersion = appVersion
        model.hoverButton = argValue("debug-hover-button")
        if let v = argValue("debug-update") { model.availableUpdate = v }
        model.onCheckUpdates = { [weak self] in self?.checkUpdatesFromPanel() }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        #if canImport(Sparkle)
        updateWatcher.onResult = { [weak self] v in self?.setAvailableUpdate(v) }
        _ = updater
        #endif
        // 切页签、切区间、历史结果到达后，面板高度跟着内容走。
        model.$tab.map { _ in () }.merge(with: model.$range.map { _ in () }, model.$geminiHistory.map { _ in () },
                                          model.$officialLoaded.map { _ in () })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitPanel() } }
            .store(in: &subs)
        model.onReauthorizeKeychain = { [weak self] in self?.source.allowKeychainAgain(); self?.refresh() }

        statusItem = makeItem()

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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }

        if args.contains("--debug-open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.printRects() }
            }
        } else if args.contains("--debug-open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showPanel(from: self.statusItem.button)
                if let n = argValue("debug-tab-flip").flatMap({ Int($0) }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.debugFlip(n, total: n, tops: [], bad: 0) }
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

    private var rows: [MenuBarGroup] { MenuBarText.rows(codex: model.codex, gemini: model.gemini) }

    /// 两家都登录 → 上下两行；只登录一家 → 单行正常字号；都没登录 → 栏量图标。
    private func updateMenuBar() {
        guard let b = statusItem.button else { return }
        let rs = rows
        if let img = MenuBarLayout.image(rs, height: NSStatusBar.system.thickness) {
            b.image = img
            statusItem.length = ceil(MenuBarLayout.width(rs)) + itemPadding
        } else {
            b.image = symbol("chart.bar.fill", label: "栏量")
            statusItem.length = NSStatusItem.variableLength
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            hidePanel()
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if panel?.isVisible == true { hidePanel(); return }
        // 默认停在上次的页签；当前页签那家没登录、另一家登录了，就切过去。
        let shown = Set(rows.map { $0.service })
        if !shown.contains(model.tab), let other = shown.first { model.tab = other }
        showPanel(from: sender)
        refresh()
    }

    // MARK: 面板

    /// 面板第一次打开时才创建（SwiftUI/Charts 不在启动时渲染）。
    private func ensurePanel() {
        guard panel == nil else { return }
        let h = NSHostingView(rootView: PanelView(model: model))
        // 不让 NSHostingView 按内容自己改尺寸（它在视效视图里会从左下角伸缩，顶部被吞或顶上留白）；
        // 尺寸只由 fitPanel 同步算出、一次设到窗口上（0.2.1 修复）。
        h.sizingOptions = []
        measurer = NSHostingController(rootView: PanelView(model: model, fill: false))
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        // 半透明圆角（契约 0.2.0 §2）：内容放在 .popover 材质里，圆角 10。
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = roundedMask(10)
        h.frame = fx.bounds
        h.autoresizingMask = [.width, .height]
        fx.addSubview(h)
        p.contentView = fx
        host = h
        panel = p
    }

    private func showPanel(from button: NSButton?) {
        ensurePanel()
        guard let button = button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let panel = panel else { return }
        let size = panelSize()
        var x = r.minX
        if let screen = win.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: r.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    /// 内容变化后保持面板顶边不动、高度跟内容走。
    private func fitPanel() {
        guard let panel = panel, panel.isVisible else { return }
        let size = panelSize()
        var f = panel.frame
        guard abs(f.height - size.height) > 0.5 || abs(f.width - size.width) > 0.5 else { return }
        f.origin.y = f.maxY - size.height      // 顶边钉在菜单栏下面不动
        f.size = size
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            panel.setFrame(f, display: true, animate: false)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    /// 按当前数据同步量出面板尺寸（宽 400）。
    private func panelSize() -> NSSize {
        guard let m = measurer else { return NSSize(width: 400, height: 300) }
        m.rootView = PanelView(model: model, fill: false)
        let s = m.sizeThatFits(in: NSSize(width: 400, height: 4000))
        // 高度上限：屏幕可见高度减边距（截图用 --debug-max-height 压低）；超过就在面板里滚动。
        var cap = ((panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 40
        if let d = argValue("debug-max-height").flatMap({ Double($0) }) { cap = CGFloat(d) }
        return NSSize(width: 400, height: min(ceil(s.height), cap))
    }

    /// 截图用：来回切页签 n 次，每次检查面板顶边、内容视图和窗口是否一致，最后打印截图区域。
    private func debugFlip(_ left: Int, total: Int, tops: [CGFloat], bad: Int) {
        if left == 0 {
            let t = tops.map { Int($0.rounded()) }
            print("DEBUG_TABFLIP flips=\(total) tab=\(model.tab.rawValue) topsUnique=\(Set(t).count) top=\(t.first ?? 0) mismatches=\(bad)")
            printRects()
            return
        }
        model.tab = model.tab == .codex ? .gemini : .codex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.fitPanel()
            guard let p = self.panel, let h = self.host, let cv = p.contentView else { return }
            let ok = abs(h.frame.height - cv.bounds.height) < 0.5 && abs(h.frame.maxY - cv.bounds.maxY) < 0.5
                && abs(self.panelSize().height - p.frame.height) < 0.5
            self.debugFlip(left - 1, total: total, tops: tops + [p.frame.maxY], bad: bad + (ok ? 0 : 1))
        }
    }

    // MARK: 刷新

    private func refresh() {
        guard !model.refreshing else { return }
        model.refreshing = true
        if let now = source.fixedNow { model.now = { now } }
        // 两家额度各自到了就各自更新菜单栏和面板（契约 0.1.5 §5）。
        source.refresh(current: (model.codex, model.gemini), handlers: RefreshHandlers(
            onCodex: { [weak self] s in
                guard let self = self else { return }
                self.model.codex = s
                self.updateMenuBar()
                DispatchQueue.main.async { self.fitPanel() }
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
                DispatchQueue.main.async { self.fitPanel() }
            },
            onAllDone: { [weak self] in
                guard let self = self else { return }
                // 截图用：--debug-loading 停在加载态（转圈、「正在统计…」）。
                if self.args.contains("--debug-loading") { return }
                self.model.refreshing = false
                self.model.lastUpdated = Date()
            }))
        // Gemini 本机历史单独在后台扫，不拖慢额度和菜单栏。
        source.refreshGeminiHistory { [weak self] h in
            guard let self = self, !self.args.contains("--debug-loading") else { return }
            self.model.geminiHistory = h
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

    // MARK: 设置窗口（契约 0.2.0 §7）

    private func openSettings() {
        hidePanel()
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
        settingsModel.onCheckUpdates = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.checkUpdates()
        }
        settingsModel.onQuit = { quitWithFallback() }
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "栏量设置"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
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
        if args.contains("--debug-open-settings"), let w = settingsWindow {
            print("DEBUG_RECT_PANEL \(top(w.frame))")
        } else if let p = panel { print("DEBUG_RECT_PANEL \(top(p.frame))") }
        let rs = rows
        let groups = rs.map { "\($0.service.rawValue):\($0.primary)\($0.secondary.map { "+" + $0 } ?? "")" }
        let content = String(format: "%.1f", MenuBarLayout.width(rs))
        print("DEBUG_MENUBAR items=\(statusItemCount) visible=\(statusItem.isVisible ? 1 : 0) autosave=\(statusItem.autosaveName ?? "") rows=\(rs.count) content=\(content) item=\(Int(itemWidth)) groups=\(groups.isEmpty ? "fallback" : groups.joined(separator: ","))")
        fflush(stdout)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
