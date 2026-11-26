import AppKit
import SwiftUI

@MainActor
enum UsageExport {
    static func write(_ report: UsageExportSnapshot, to directory: URL? = nil) throws -> URL {
        let target = try directory ?? FileManager.default.url(for: .downloadsDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let renderer = ImageRenderer(content: UsageExportView(snapshot: report))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 600, height: nil)
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
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

private struct UsageExportView: View {
    let snapshot: UsageExportSnapshot

    private let ink = Color(red: 0.10, green: 0.14, blue: 0.20)
    private let muted = Color(red: 0.30, green: 0.35, blue: 0.42)
    private let canvas = Color(red: 0.94, green: 0.96, blue: 0.98)
    private let rule = Color(red: 0.89, green: 0.91, blue: 0.94)

    private func color(_ service: Service) -> Color { service == .codex ? Theme.accent : Theme.purple }
    private func display(_ service: Service) -> String { service.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("栏量  /  用量报告")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(muted)
                Text("消耗汇总")
                    .font(.system(size: 30, weight: .bold)).foregroundColor(ink)
                Text("\(snapshot.range.title) · \(snapshot.dateText)")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundColor(muted)
            }
            card {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Token 用量").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(snapshot.groups.contains(where: \.hasTokenData) ? "\(Fmt.tokens(snapshot.total)) Tokens" : "暂无数据")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                }
                HStack(spacing: 14) {
                    ForEach(snapshot.groups, id: \.service) { group in
                        HStack(spacing: 5) {
                            Circle().fill(color(group.service)).frame(width: 7, height: 7)
                            Text(display(group.service) + (group.hasTokenData ? "" : " · 暂无用量数据"))
                        }
                        .font(.system(size: 11)).foregroundColor(muted)
                    }
                }
                if snapshot.groups.contains(where: \.hasTokenData) {
                    BarChart(bars: snapshot.bars.map(\.bar), active: nil,
                        axisKeys: Set(TokenChartSection.axisKeysFor(snapshot.bars.map(\.bar), range: snapshot.range)),
                        axisLabel: { TokenChartSection.axisLabelFor($0, range: snapshot.range) },
                        hover: .constant(nil),
                        stacks: Dictionary(uniqueKeysWithValues: snapshot.bars.map { ($0.bar.key, $0) }))
                        .frame(height: 132)
                }
            }
            card {
                Text("模型分布").font(.system(size: 16, weight: .semibold))
                ForEach(snapshot.groups, id: \.service) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(display(group.service)).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(group.service == .codex ? "按活跃会话 · 最后使用的模型" : "按本机 Token")
                                .font(.system(size: 11)).foregroundColor(muted)
                        }
                        if let shares = group.shares, !shares.isEmpty {
                            ForEach(shares) { share in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(share.name).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(share.tenths % 10 == 0 ? "\(share.tenths / 10)%" :
                                             "\(share.tenths / 10).\(share.tenths % 10)%")
                                            .fontWeight(.semibold).monospacedDigit()
                                    }
                                    .font(.system(size: 12))
                                    GeometryReader { geometry in
                                        Capsule().fill(rule)
                                            .overlay(alignment: .leading) {
                                                Capsule().fill(color(group.service))
                                                    .frame(width: geometry.size.width * CGFloat(share.tenths) / 1000)
                                            }
                                    }
                                    .frame(height: 5)
                                }
                            }
                        } else {
                            Text(group.shares == nil ? "本机暂无法取得模型数据" : "这段时间没有模型记录")
                                .font(.system(size: 12)).foregroundColor(muted)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 9).fill(canvas.opacity(0.65)))
                }
            }
        }
        .foregroundColor(ink)
        .padding(24)
        .frame(width: 600)
        .background(canvas)
        .environment(\.colorScheme, .light)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(rule, lineWidth: 1))
    }
}
