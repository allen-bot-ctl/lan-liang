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
    private var items: [Service: NSStatusItem] = [:]
    private var fallbackItem: NSStatusItem!
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

        if let dir = argValue("debug-render") {
            source.loadSync(into: model)
            renderPanels(to: dir)
            exit(0)
        }

        // 先建的状态项在右边：栏量兜底图标 → Gemini → Codex（Codex 在最左）。
        fallbackItem = makeItem(tag: -1)
        fallbackItem.button?.image = symbol("chart.bar.fill", label: "栏量")
        items[.gemini] = makeItem(tag: 1)
        items[.codex] = makeItem(tag: 0)

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
                self.showPanel(from: self.items[self.model.tab]?.button ?? self.fallbackItem.button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.printRects() }
            }
        }
    }

    // MARK: 菜单栏

    private func makeItem(tag: Int) -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = it.button {
            b.tag = tag
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeft
        }
        return it
    }

    private func symbol(_ name: String, label: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        img?.isTemplate = true
        return img
    }

    private func icon(for s: Service) -> NSImage? {
        s == .codex ? symbol("terminal", label: "Codex") : symbol("sparkle", label: "Gemini")
    }

    private func title(primary: String, secondary: String?) -> NSAttributedString {
        let t = NSMutableAttributedString(string: " " + primary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor])
        if let s = secondary {
            t.append(NSAttributedString(string: " " + s, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.5]))
        }
        return t
    }

    /// 按最长「100% 100%」锁定宽度，数字变化不跳动。
    private func lockedWidth(hasSecondary: Bool) -> CGFloat {
        let w = title(primary: "100%", secondary: hasSecondary ? "100%" : nil).size().width
        return ceil(w + 16 + 3 + 8)
    }

    private func updateMenuBar() {
        var anyShown = false
        for s in Service.allCases {
            guard let it = items[s] else { continue }
            if let g = MenuBarText.group(for: s, snapshot: model.snapshot(s)) {
                it.isVisible = true
                it.button?.image = icon(for: s)
                it.button?.attributedTitle = title(primary: g.primary, secondary: g.secondary)
                it.length = lockedWidth(hasSecondary: g.secondary != nil)
                anyShown = true
            } else {
                it.isVisible = false
            }
        }
        fallbackItem.isVisible = !anyShown
    }

    @objc private func clicked(_ sender: NSButton) {
        let item = sender.tag == 0 ? items[.codex] : sender.tag == 1 ? items[.gemini] : fallbackItem
        if NSApp.currentEvent?.type == .rightMouseUp {
            hidePanel()
            item?.menu = contextMenu
            item?.button?.performClick(nil)
            item?.menu = nil
            return
        }
        if panel?.isVisible == true { hidePanel(); return }
        if sender.tag == 1 { model.tab = .gemini } else if sender.tag == 0 { model.tab = .codex }
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
        var union: NSRect?
        for it in [items[.codex], items[.gemini], fallbackItem] {
            guard let it = it, it.isVisible, let b = it.button, let w = b.window else { continue }
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            union = union.map { $0.union(r) } ?? r
        }
        if let u = union { print("DEBUG_RECT_ITEM \(top(u))") }
        if let p = panel { print("DEBUG_RECT_PANEL \(top(p.frame))") }
        let groups = Service.allCases.compactMap { s in MenuBarText.group(for: s, snapshot: model.snapshot(s)) }
            .map { "\($0.service.rawValue):\($0.primary)\($0.secondary.map { "+" + $0 } ?? "")" }
        print("DEBUG_MENUBAR groups=\(groups.isEmpty ? "fallback" : groups.joined(separator: ","))")
        fflush(stdout)
    }

    /// 把面板放进屏幕外窗口，用 cacheDisplay 渲染成 2x PNG（AppKit 控件也能画出来）。
    private func snapshotPanel(appearance ap: String, to url: URL) -> Bool {
        let view = NSHostingView(rootView: PanelView(model: model))
        let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 360, height: 400),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: ap == "dark" ? .darkAqua : .aqua)
        win.backgroundColor = .windowBackgroundColor
        win.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        win.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        win.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        view.display()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        win.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// 离屏渲染面板（页签 × 每日/每周/每月，深浅各一张 2x），写到目录后退出。
    private func renderPanels(to path: String) {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = argValue("debug-render-prefix") ?? "panel"
        var count = 0
        for ap in ["dark", "light"] {
            for tab in Service.allCases {
                for range in (tab == .codex ? TokenRange.allCases : [.daily]) {
                    model.tab = tab
                    model.range = range
                    let name = tab == .codex ? "\(prefix)-codex-\(range.rawValue)-\(ap).png" : "\(prefix)-gemini-\(ap).png"
                    if snapshotPanel(appearance: ap, to: dir.appendingPathComponent(name)) { count += 1 }
                }
            }
        }
        print("DEBUG_RENDER count=\(count)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
