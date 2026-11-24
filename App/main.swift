import AppKit
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// 无边框浮层面板：点菜单栏项打开，点别处关闭。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let model = PanelModel()
    private var panel: FloatingPanel!
    private var outsideMonitor: Any?
    private let contextMenu = NSMenu()
    private let args = CommandLine.arguments

    #if canImport(Sparkle)
    /// 还没配置 Sparkle 公钥时不启动更新器，避免启动就弹错误框。
    private let updater = SPUStandardUpdaterController(
        startingUpdater: !((Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").isEmpty,
        updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ n: Notification) {
        if let a = args.first(where: { $0.hasPrefix("--debug-appearance=") }) {
            NSApp.appearance = NSAppearance(named: a.hasSuffix("light") ? .aqua : .darkAqua)
        }
        if let a = args.first(where: { $0.hasPrefix("--debug-render=") }) {
            renderPanels(to: String(a.dropFirst("--debug-render=".count)))
            exit(0)
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.title = "栏量"
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        contextMenu.addItem(withTitle: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出栏量", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.addItem(quit)

        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame.size = host.fittingSize
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = host

        if args.contains("--debug-open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showPanel(); self.printRects() }
        }
    }

    @objc private func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.menu = contextMenu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = item.button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        var x = r.midX - size.width / 2
        if let screen = win.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: r.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    /// 打印截图区域（左上原点、单位点），供 scripts/ci_screenshots.sh 用 screencapture -R 裁剪。
    private func printRects() {
        guard let screen = NSScreen.screens.first else { return }
        let h = screen.frame.height
        func top(_ r: NSRect) -> String { "\(Int(r.minX)),\(Int(h - r.maxY)),\(Int(r.width)),\(Int(r.height))" }
        let menubarHeight = NSStatusBar.system.thickness
        print("DEBUG_RECT_MENUBAR \(top(NSRect(x: 0, y: h - menubarHeight, width: screen.frame.width, height: menubarHeight)))")
        if let b = item.button, let w = b.window {
            print("DEBUG_RECT_ITEM \(top(w.convertToScreen(b.convert(b.bounds, to: nil))))")
        }
        print("DEBUG_RECT_PANEL \(top(panel.frame))")
        print("DEBUG_SCALE \(screen.backingScaleFactor)")
        fflush(stdout)
    }

    /// 离屏渲染面板（每个页签深浅各一张 2x），写到目录后退出。
    private func renderPanels(to path: String) {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = PanelModel()
        var count = 0
        for ap in ["dark", "light"] {
            for tab in Service.allCases {
                m.tab = tab
                let v = PanelView(model: m)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, ap == "dark" ? .dark : .light)
                NSAppearance(named: ap == "dark" ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    let r = ImageRenderer(content: v)
                    r.scale = 2
                    if let cg = r.cgImage,
                       let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("panel-\(tab.rawValue)-\(ap).png"))
                        count += 1
                    }
                }
            }
        }
        print("DEBUG_RENDER count=\(count)")
        fflush(stdout)
    }

    @objc private func checkUpdates() {
        #if canImport(Sparkle)
        updater.checkForUpdates(nil)
        #endif
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
