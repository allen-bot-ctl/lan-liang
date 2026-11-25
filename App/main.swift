import AppKit
import SwiftUI
import ServiceManagement
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
    private var outsideMonitor: Any?
    private let contextMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private lazy var source: DataSource = makeDataSource()
    private let args = CommandLine.arguments
    private var isDebug: Bool { args.contains { $0.hasPrefix("--debug-") } || ProcessInfo.processInfo.environment["LANLIANG_FAKE"] != nil }

    #if canImport(Sparkle)
    /// 没配置 Sparkle 公钥时不启动更新器，避免启动就弹错误框。
    private let updater = SPUStandardUpdaterController(
        startingUpdater: !((Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").isEmpty,
        updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ n: Notification) {
        if let a = argValue("debug-appearance") {
            NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
        }
        if let t = argValue("debug-tab"), let s = Service(rawValue: t) { model.tab = s }
        if let r = argValue("debug-range"), let v = TokenRange(rawValue: r) { model.range = v }
        model.hoverKey = argValue("debug-hover")
        model.onRefresh = { [weak self] in self?.refresh() }
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

        if args.contains("--debug-open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showPanel(from: self.statusItem.button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.printRects() }
            }
        }
    }

    // MARK: 菜单栏

    private func makeItem() -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.backgroundColor = .windowBackgroundColor
        p.contentView = h
        host = h
        panel = p
    }

    private func showPanel(from button: NSButton?) {
        ensurePanel()
        guard let button = button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let panel = panel, let host = host else { return }
        let size = host.fittingSize
        var x = r.minX
        if let screen = win.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: r.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
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
        guard let host = host else { return }
        let size = host.fittingSize
        var f = panel.frame
        f.origin.y = f.maxY - size.height
        f.size = size
        panel.setFrame(f, display: true)
    }

    // MARK: 刷新

    private func refresh() {
        guard !model.refreshing else { return }
        model.refreshing = true
        source.refresh(current: (model.codex, model.gemini)) { [weak self] result in
            guard let self = self else { return }
            self.model.codex = result.codex
            self.model.gemini = result.gemini
            self.model.official = result.official
            self.model.local = result.local
            if let now = result.now { self.model.now = { now } }
            self.model.refreshing = false
            self.updateMenuBar()
            DispatchQueue.main.async { self.fitPanel() }
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
    }

    @objc private func checkUpdates() {
        #if canImport(Sparkle)
        updater.checkForUpdates(nil)
        #endif
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
        print("DEBUG_MENUBAR items=\(statusItemCount) rows=\(rs.count) content=\(content) item=\(Int(itemWidth)) groups=\(groups.isEmpty ? "fallback" : groups.joined(separator: ","))")
        fflush(stdout)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
