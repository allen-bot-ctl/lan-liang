import AppKit

@MainActor
enum UsageExport {
    static func write(_ report: UsageExportSnapshot, to directory: URL? = nil) throws -> URL {
        let target = try directory ?? FileManager.default.url(for: .downloadsDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let png = try UsageReportDrawing(snapshot: report).png()
        for _ in 0..<4 {
            let name = "栏量-消耗汇总-\(report.start)-\(UUID().uuidString.prefix(8)).png"
            let url = target.appendingPathComponent(name)
            do {
                try png.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

/// Off-screen CPU bitmap. Uses the same data and axes as the app without requiring a display or Metal device.
@MainActor
private struct UsageReportDrawing {
    let snapshot: UsageExportSnapshot

    private let width: CGFloat = 600
    private let ink = NSColor(srgbRed: 0.10, green: 0.14, blue: 0.20, alpha: 1)
    private let muted = NSColor(srgbRed: 0.32, green: 0.37, blue: 0.44, alpha: 1)
    private let canvas = NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1)
    private let rule = NSColor(srgbRed: 0.87, green: 0.90, blue: 0.94, alpha: 1)
    private let orange = NSColor(srgbRed: 0.91, green: 0.43, blue: 0.15, alpha: 1)
    private let purple = NSColor(srgbRed: 0.48, green: 0.43, blue: 0.83, alpha: 1)

    private var hasTokens: Bool { snapshot.groups.contains(where: \.hasTokenData) }
    private var tokenHeight: CGFloat { hasTokens ? 197 : 82 }
    private var modelsHeight: CGFloat { 58 + snapshot.groups.reduce(0) { $0 + groupHeight($1) + 8 } }
    private var height: CGFloat { 136 + tokenHeight + modelsHeight }
    private func color(_ service: Service) -> NSColor { service == .codex ? orange : purple }

    private func groupHeight(_ group: UsageExportSnapshot.Group) -> CGFloat {
        let rows = group.shares?.count ?? 0
        return rows == 0 ? 58 : 40 + CGFloat(rows) * 29
    }

    func png() throws -> Data {
        let scale = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        background(canvas, x: 0, y: 0, w: width, h: height)
        background(orange, x: 24, y: 26, w: 4, h: 16, radius: 2)
        text("栏量  /  用量报告", x: 36, y: 25, w: 300, size: 12, weight: .semibold, color: muted)
        text("消耗汇总", x: 24, y: 49, w: 520, size: 31, weight: .bold)
        text("\(snapshot.range.title) · \(snapshot.dateText)", x: 25, y: 88, w: 520, size: 13, color: muted)
        tokenCard(top: 112)
        modelCard(top: 124 + tokenHeight)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x, y: height - y - h, width: w, height: h)
    }

    private func background(_ color: NSColor, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat = 0) {
        guard w > 0, h > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius).fill()
    }

    private func card(y: CGFloat, h: CGFloat) {
        let path = NSBezierPath(roundedRect: rect(24, y, 552, h), xRadius: 13, yRadius: 13)
        NSColor.white.setFill()
        path.fill()
        rule.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func text(_ value: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular, color: NSColor? = nil,
                      align: NSTextAlignment = .left, numeric: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingMiddle
        let font = numeric ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                           : NSFont.systemFont(ofSize: size, weight: weight)
        (value as NSString).draw(with: rect(x, y, w, ceil(size * 1.45)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color ?? ink, .paragraphStyle: paragraph])
    }

    private func tokenCard(top: CGFloat) {
        card(y: top, h: tokenHeight)
        text("Token 用量", x: 40, y: top + 14, w: 220, size: 16, weight: .semibold)
        text(hasTokens ? "\(Fmt.tokens(snapshot.total)) Tokens" : "暂无数据",
             x: 270, y: top + 13, w: 290, size: 17, weight: .semibold, align: .right, numeric: true)
        for (i, group) in snapshot.groups.enumerated() {
            let x = CGFloat(40 + i * 185)
            background(color(group.service), x: x, y: top + 48, w: 7, h: 7, radius: 3.5)
            text(group.service.title + (group.hasTokenData ? "" : " · 暂无用量数据"),
                 x: x + 12, y: top + 44, w: 172, size: 11, color: muted)
        }
        guard hasTokens, !snapshot.bars.isEmpty else { return }
        let left: CGFloat = 106
        let right: CGFloat = 552
        let plotTop = top + 74
        let plotHeight: CGFloat = 89
        let maxTotal = StackedSeries.axisMax(snapshot.bars)
        for frac in [0.0, 0.5, 1.0] {
            let y = plotTop + (1 - frac) * plotHeight
            let value = frac == 1 ? maxTotal : Int64(Double(maxTotal) * frac)
            text(Fmt.axisTokens(value), x: 39, y: y - 7, w: 58,
                 size: 10, color: muted, align: .right, numeric: true)
            background(rule, x: left, y: y, w: right - left, h: 0.7)
        }
        let slot = (right - left) / CGFloat(snapshot.bars.count)
        let barWidth = min(70, slot * 0.68)
        let axisKeys = Set(TokenChartSection.axisKeysFor(snapshot.bars.map(\.bar), range: snapshot.range))
        for (i, stack) in snapshot.bars.enumerated() {
            let center = left + (CGFloat(i) + 0.5) * slot
            let codexH = CGFloat(Double(stack.codex) / Double(maxTotal)) * plotHeight
            let geminiH = CGFloat(Double(stack.gemini) / Double(maxTotal)) * plotHeight
            let bottom = plotTop + plotHeight
            background(orange, x: center - barWidth / 2, y: bottom - codexH, w: barWidth, h: codexH)
            background(purple, x: center - barWidth / 2, y: bottom - codexH - geminiH, w: barWidth, h: geminiH)
            if axisKeys.contains(stack.bar.key) {
                let label = TokenChartSection.axisLabelFor(stack.bar.key, range: snapshot.range)
                text(label, x: center - 21, y: bottom + 7, w: 42, size: 10, color: muted, align: .center, numeric: true)
            }
        }
    }

    private func modelCard(top: CGFloat) {
        card(y: top, h: modelsHeight)
        text("模型分布", x: 40, y: top + 15, w: 200, size: 16, weight: .semibold)
        var y = top + 44
        for group in snapshot.groups {
            let groupH = groupHeight(group)
            background(canvas, x: 40, y: y, w: 520, h: groupH, radius: 9)
            background(color(group.service), x: 52, y: y + 17, w: 7, h: 7, radius: 3.5)
            text(group.service.title, x: 65, y: y + 12, w: 160, size: 13, weight: .semibold)
            let basis = group.service == .codex ? "按活跃会话 · 最后使用的模型" : "按本机 Token"
            text(basis, x: 230, y: y + 14, w: 316, size: 11, color: muted, align: .right)
            if let shares = group.shares, !shares.isEmpty {
                for (i, share) in shares.enumerated() {
                    let rowY = y + 36 + 29 * CGFloat(i)
                    let percent = share.tenths % 10 == 0 ? "\(share.tenths / 10)%" :
                        "\(share.tenths / 10).\(share.tenths % 10)%"
                    text(share.name, x: 52, y: rowY, w: 395, size: 12)
                    text(percent, x: 451, y: rowY, w: 97, size: 12,
                         weight: .semibold, align: .right, numeric: true)
                    background(rule, x: 52, y: rowY + 18, w: 496, h: 5, radius: 2.5)
                    background(color(group.service), x: 52, y: rowY + 18,
                               w: 496 * CGFloat(share.tenths) / 1000, h: 5, radius: 2.5)
                }
            } else {
                text(group.shares == nil ? "本机暂无法取得模型数据" : "这段时间没有模型记录",
                     x: 52, y: y + 34, w: 496, size: 12, color: muted)
            }
            y += groupH + 8
        }
    }
}
