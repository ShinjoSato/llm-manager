import SwiftUI
import MonitorKit

/// 直前の発話の下に畳むツール群。「ツール N件 ▸」を開くと名前と対象を並べる。
struct ToolsRow: View {
    let tools: [TranscriptItem]
    let runningToolId: String?
    @State private var expanded = false

    var body: some View {
        let running = tools.first { $0.id == runningToolId }
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 11))
                    Text("ツール \(tools.count)件")
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    if let running {
                        ProgressView().controlSize(.mini).tint(ChatTheme.working)
                        Text("実行中: \(running.tool?.name ?? "")")
                            .font(ChatTheme.mono)
                            .foregroundStyle(ChatTheme.working)
                    }
                }
                .font(ChatTheme.caption)
                .foregroundStyle(running != nil ? ChatTheme.working : ChatTheme.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(running != nil ? ChatTheme.working.opacity(0.1) : ChatTheme.inputSurface))
                .overlay(Capsule().stroke(running != nil ? ChatTheme.working.opacity(0.4) : ChatTheme.border))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { tool in
                        let isRunning = tool.id == runningToolId
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(tool.tool?.name ?? "?")
                                .foregroundStyle(isRunning ? ChatTheme.working : ChatTheme.text)
                                .fontWeight(.semibold)
                            Text(tool.tool?.target ?? tool.tool?.description ?? "")
                                .foregroundStyle(isRunning ? ChatTheme.working : ChatTheme.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(ChatTheme.mono)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.codeSurface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.border))
            }
        }
    }
}
