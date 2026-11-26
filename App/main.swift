import AppKit
import SwiftUI
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

/// 无边框浮层面板：悬停预览、点按固定，点别处关闭。
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
    private var host: NSHostingView<PanelRoot>?
    private let settingsModel = SettingsModel()
    private var outsideMonitor: Any?
    private let itemHoverTracking = HoverTracking()
    private let panelHoverTracking = HoverTracking()
    private var hover = MenuPanelHover()
    private var hoverCloseTimer: Timer?
    private var hoverEnabled: Bool { !isDebug || args.contains("--debug-hover-lifecycle") }
    private let contextMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
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
        // 监听服务（契约 0.3.0 §1）：截图用 --debug-services 覆盖，不写盘。
        model.services = debugServices ?? ServiceSelection.load(from: .standard)
        keepTabEnabled()
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
        model.onReauthorizeKeychain = { [weak self] in self?.source.allowKeychainAgain(); self?.refresh() }

        statusItem = makeItem()
        itemHoverTracking.didEnter = { [weak self] in self?.hoverItemEntered() }
        itemHoverTracking.didLeave = { [weak self] in self?.hoverRegionLeft() }
        panelHoverTracking.didEnter = { [weak self] in self?.hoverPanelEntered() }
        panelHoverTracking.didLeave = { [weak self] in self?.hoverRegionLeft() }
        if hoverEnabled, let button = statusItem.button { itemHoverTracking.attach(to: button) }
        // 菜单栏深浅色变化（系统外观、壁纸着色）时重画，文字颜色跟着变（0.3.2）。
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateMenuBar() }
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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }

        if args.contains("--debug-hover-lifecycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.debugHoverLifecycle() }
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

    /// 只显示开着的服务（契约 0.3.0 §1）。
    private var rows: [MenuBarGroup] { MenuBarText.rows(codex: model.codex, gemini: model.gemini, selection: model.services) }

    /// 只开了一个服务 → 放大单行（契约 0.3.0 §2）；两个都开时不变。
    private var largeMenuBar: Bool { model.services.isSingle }

    /// 两家都登录 → 上下两行；只登录一家 → 单行正常字号；只开一个服务 → 单行放大；都没登录 → 栏量图标。
    private func updateMenuBar() {
        guard let b = statusItem.button else { return }
        let rs = rows
        let large = largeMenuBar
        // 0.3.2：内容图不是模板图（5 小时剩余画品牌橙），颜色按按钮当前外观解析。
        if let img = MenuBarLayout.image(rs, height: NSStatusBar.system.thickness, large: large,
                                         appearance: b.effectiveAppearance) {
            b.image = img
            statusItem.length = ceil(MenuBarLayout.width(rs, large: large)) + itemPadding
        } else {
            b.image = symbol("chart.bar.fill", label: "栏量")
            statusItem.length = NSStatusItem.variableLength
        }
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
        cancelHoverClose()
        hover.click()
        if hover.mode == .hidden { hidePanel() }
        else { openMenuPanel(from: sender) }
    }

    private func openMenuPanel(from sender: NSButton?) {
        guard panel?.isVisible != true else { return }
        // 默认停在上次的页签；当前页签那家没登录、另一家登录了，就切过去。
        keepTabEnabled()
        let shown = Set(rows.map { $0.service })
        if !shown.contains(model.tab), let other = shown.first { model.tab = other }
        showPanel(from: sender)
        guard panel?.isVisible == true else { hover.hide(); return }
        refresh()
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
        model.refreshing = true
        if model.showsSettings { loadCodexModelActivity() }
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
        // Gemini 本机历史单独在后台扫，不拖慢额度和菜单栏；Gemini 关掉时不扫。
        guard selection.gemini else { return }
        source.refreshGeminiHistory { [weak self] h in
            guard let self = self, !self.args.contains("--debug-loading") else { return }
            self.model.geminiHistory = h
        }
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
        updateMenuBar()
        if on {
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
        let large = largeMenuBar
        let content = String(format: "%.1f", MenuBarLayout.width(rs, large: large))
        let style = rs.count >= 2 ? "compact" : (large ? "large" : "single")
        let cells = rs.map { "\($0.service.rawValue):\(MenuBarLayout.cellText($0))" }.joined(separator: ",")
        let dark = (statusItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ? 1 : 0
        print("DEBUG_MENUBAR_WIDTH content=\(content) item=\(Int(itemWidth)) style=\(rs.count >= 2 ? "compact" : (large ? "large" : "single"))")
        print("DEBUG_MENUBAR_CELLS cells=\(cells.isEmpty ? "fallback" : cells) dark=\(dark) template=\(statusItem.button?.image?.isTemplate == true ? 1 : 0)")
        print("DEBUG_MENUBAR items=\(statusItemCount) visible=\(statusItem.isVisible ? 1 : 0) autosave=\(statusItem.autosaveName ?? "") rows=\(rs.count) content=\(content) item=\(Int(itemWidth)) groups=\(groups.isEmpty ? "fallback" : groups.joined(separator: ",")) services=\(model.services.debugText) style=\(style)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
