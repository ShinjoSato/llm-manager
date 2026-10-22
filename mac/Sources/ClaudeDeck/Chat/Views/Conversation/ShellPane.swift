import AppKit
import SwiftUI
import MonitorKit

/// 会話の上の「Claude」「ターミナル」のタブ。
struct RoomTabBar: View {
    let selection: RoomTab
    /// ターミナルのシェルが動いているか（タブに印を出す）。
    let shellRunning: Bool
    let select: (RoomTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RoomTab.allCases, id: \.self) { tab in
                RoomTabButton(tab: tab, selected: tab == selection, running: tab == .terminal && shellRunning) { select(tab) }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .headerBackground()
    }
}

private struct RoomTabButton: View {
    let tab: RoomTab
    let selected: Bool
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol).font(.system(size: 11, weight: .medium))
                Text(tab.label).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                if running { Circle().fill(ChatTheme.working).frame(width: 5, height: 5) }
            }
            .foregroundStyle(selected ? ChatTheme.heading : ChatTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !selected ? ChatTheme.selectedRow : .clear))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(ChatTheme.selectionInk).frame(height: 2).padding(.horizontal, 6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(running ? "\(tab.label)（シェルが動いています）" : tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

/// ターミナルのタブの中身。開いた時にシェルを起動し、終わったら「もう一度開く」を出す。
struct ShellPane: View {
    let model: ChatModel
    let room: Room
    /// この画面（メインか別ウィンドウ）の印。端末は名乗り出た最後の 1 か所にだけ載る。
    @State private var hostId = UUID()

    var body: some View {
        let shells = model.shells
        Group {
            if !RoomShells.canOpen(room.cwd) {
                CenterPlaceholder(symbol: "terminal", text: "このルームのフォルダが分からないため、ターミナルを開けません。")
            } else if let shell = shells.shell(for: room.id) {
                content(shell)
            } else {
                CenterPlaceholder(symbol: "terminal", text: "ターミナルを起動しています…")
            }
        }
        .background(ChatTheme.background)
        .onAppear { shells.open(room) }
    }

    @ViewBuilder
    private func content(_ shell: RoomShell) -> some View {
        switch shell.phase {
        case .failed(let reason):
            VStack(spacing: 12) {
                CenterPlaceholder(symbol: "exclamationmark.triangle", text: reason).frame(maxHeight: 120)
                Button("もう一度開く") { shell.start() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notStarted:
            CenterPlaceholder(symbol: "terminal", text: "ターミナルを起動しています…")
                .onAppear { shell.start() }
        case .running, .exited:
            VStack(spacing: 0) {
                ZStack {
                    ShellTerminalHost(shell: shell, hostId: hostId)
                        .padding(.leading, 8)
                        .padding(.vertical, 4)
                    if let owner = shell.hosts.owner, owner != hostId {
                        ShownElsewhere { shell.claim(hostId) }
                    }
                }
                if case .exited(let code) = shell.phase {
                    ShellEndedBar(code: code) { shell.start() }
                }
            }
        }
    }
}

/// 同じルームの端末を別のウィンドウで出している間の案内。
private struct ShownElsewhere: View {
    let showHere: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 26)).foregroundStyle(ChatTheme.tertiary)
            Text("このターミナルは別のウィンドウに表示しています。").font(ChatTheme.body).foregroundStyle(ChatTheme.secondary)
            Button("ここに表示", action: showHere)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.background)
    }
}

/// シェルが終わった時の帯。
private struct ShellEndedBar: View {
    let code: Int32?
    let reopen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle").foregroundStyle(ChatTheme.tertiary)
            Text(code.map { "シェルは終了しました（終了コード \($0)）" } ?? "シェルは終了しました")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            Spacer()
            Button("もう一度開く", action: reopen)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .headerBackground()
    }
}

/// SwiftTerm の端末ビューを載せる入れ物。端末そのものはシェルが持ち、出す場所だけをここで名乗る。
private struct ShellTerminalHost: NSViewRepresentable {
    let shell: RoomShell
    let hostId: UUID

    func makeNSView(context: Context) -> ShellHostView {
        let view = ShellHostView(id: hostId)
        view.shell = shell
        return view
    }

    func updateNSView(_ view: ShellHostView, context: Context) {
        guard view.shell !== shell else { return }
        view.detach()
        view.shell = shell
        view.sync()
    }

    static func dismantleNSView(_ view: ShellHostView, coordinator: ()) {
        view.detach()
    }
}
