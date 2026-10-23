import SwiftUI
import MonitorKit

/// 外部ルームの見出し下に出す制約の説明と「アプリに引き継ぐ」。
struct ExternalBanner: View {
    let model: ChatModel
    let room: Room

    var body: some View {
        let busy = room.sessionId.map { model.handover.inProgress.contains($0) } ?? false
        let disabledReason = model.handover.disabledReason(for: room)
        let sourceReason = model.handover.sourceReason(for: room)
        let pending = room.sessionId.flatMap { model.restorer.pending(sessionId: $0) }
        let showsHandover: Bool = {
            guard !busy, sourceReason == nil else { return false }
            switch pending {
            case nil: return true
            // 見送り中は、前の claude が終わらない時の逃げ道として使える時だけ出す。
            case .deferred: return disabledReason == nil
            case .judging, .waiting: return false
            }
        }()
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: pending != nil ? "arrow.clockwise.circle"
                  : room.snapshot?.entrypoint == "cli" ? "terminal" : "macwindow")
                .font(.system(size: 14))
                .foregroundStyle(ChatTheme.waiting)
            Text(description(pending: pending, sourceReason: sourceReason, showsHandover: showsHandover))
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
                Text("引き継ぎ中…").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            } else if pending == .waiting || pending == .judging {
                ProgressView().controlSize(.small)
                Text(pending == .waiting ? "終了を待っています…" : "確かめています…")
                    .font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            } else {
                if case .deferred = pending, let sessionId = room.sessionId {
                    actionButton("再開する", systemImage: "arrow.clockwise", enabled: true,
                                 help: "前の claude が終わっていればこのアプリで再開し、終わる途中なら終わるのを待ってから再開します") {
                        model.restorer.resumeDeferred(sessionId: sessionId)
                    }
                }
                if showsHandover {
                    actionButton("アプリに引き継ぐ", systemImage: "arrow.down.app", enabled: disabledReason == nil,
                                 help: disabledReason ?? "元のターミナルの claude を終了し、このアプリで同じ会話を再開します") {
                        model.handover.request(room)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(ChatTheme.externalBanner)
        .overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
    }

    private func actionButton(_ title: String, systemImage: String, enabled: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? ChatTheme.onAccent : ChatTheme.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(enabled ? ChatTheme.accent : ChatTheme.inputSurface))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .fixedSize()
    }

    private func description(pending: SessionRestorer.Pending?, sourceReason: String?, showsHandover: Bool) -> String {
        let limits = "ここから送れるのは『伝言』と権限の許可・拒否だけです。"
        switch pending {
        case .judging:
            return "前回アプリでホストしていた会話です。このアプリで再開できるか確かめています。" + limits
        case .waiting:
            return "前回アプリでホストしていた会話です。前の claude が終わったら、このアプリで再開します。" + limits
        case .deferred:
            return "前回アプリでホストしていた会話です（再開を見送っています）。" + limits
                + "［再開する］で、このアプリで同じ会話を再開します。"
                + (showsHandover ? "前の claude が終わらない時は［アプリに引き継ぐ］で止めてから再開できます。" : "")
        case nil:
            return SessionHandover.sourceDescription(entrypoint: room.snapshot?.entrypoint) + limits
                + (sourceReason.map { "\($0)。" } ?? "引き継ぐと、元のターミナルの claude を終了してこのアプリで会話を再開します。")
        }
    }
}

/// アプリから送った伝言。本人の発話（青）と区別するため点線の枠で描く。
struct RelayBubble: View {
    let text: String
    let state: RelayNote.State
    var images: [ChatImage] = []
    var imageSource: ChatImageSource?

    var body: some View {
        let shape = BubbleShape.outgoing
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "envelope").font(.system(size: 10))
                Text("伝言")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ChatTheme.permission)
            if !images.isEmpty, let imageSource {
                ChatImageGrid(images: images, source: imageSource)
            }
            Text(ChatMarkdown.inline(text))
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.text)
                .textSelection(.enabled)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(shape.fill(ChatTheme.relayFill))
                .overlay(shape.stroke(ChatTheme.permission.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .sending:
            Text("送信中…").font(.system(size: 11)).foregroundStyle(ChatTheme.tertiary)
        case .sent:
            Text("別セッションからのメッセージとして送りました").font(.system(size: 11)).foregroundStyle(ChatTheme.tertiary)
        case .failed(let reason):
            Label("送れませんでした: \(reason)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.error)
        }
    }
}

/// 外部セッションが権限待ちなのにアプリに確認が来ていない（Channels を載せていない）時の案内。
struct ChannelsMissingCard: View {
    let toolName: String?
    /// 権限待ちになった直後はアプリに確認が届く前なので、少し待ってから出す。
    @State private var shown = false

    var body: some View {
        Group {
            if shown { card }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            shown = true
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield").foregroundStyle(ChatTheme.permission)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("権限の確認待ち").font(.system(size: 13, weight: .bold)).foregroundStyle(ChatTheme.heading)
                    if let toolName, !toolName.isEmpty {
                        Text(toolName).font(ChatTheme.mono.weight(.semibold)).foregroundStyle(ChatTheme.permission)
                    }
                }
                Text("確認がまだ届いていません。Channels を載せていないセッションは、ここからは答えられません（ターミナルで答えてください）。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.pendingCardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.permission.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
