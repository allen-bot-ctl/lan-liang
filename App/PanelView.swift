import SwiftUI

/// 面板模型：骨架阶段只有页签与占位内容。
final class PanelModel: ObservableObject {
    @Published var tab: Service = .codex
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("栏量").font(.headline)
                Spacer()
            }
            Picker("", selection: $model.tab) {
                Text("Codex").tag(Service.codex)
                Text("Gemini").tag(Service.gemini)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.tab == .codex ? "Codex 数据接入中" : "Gemini 数据接入中")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
        .padding(16)
        .frame(width: 360)
    }
}
