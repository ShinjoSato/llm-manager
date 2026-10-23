import SwiftUI
import MonitorKit

/// 外部ルームの見出し下に出す制約の説明と「アプリに引き継ぐ」（VS Code の会話は「タブを閉じたら」と「今すぐ止めて」）。
struct ExternalBanner: View {
    let model: ChatModel
    let room: Room
    /// 狭い時はボタンをアイコンだけにして、説明に幅を回す（帯が縦に伸びないように）。
    @State private var compact = false
    private static let compactWidth: CGFloat = 820

    var body: some View {
        let busy = room.sessionId.map { model.handover.inProgress.contains($0) } ?? false
        let closeWait = room.sessionId.flatMap { model.handover.closeWaitPhase(sessionId: $0) }
        let disabledReason = model.handover.disabledReason(for: room)
        let source = model.handover.source(for: room)
        let sourceReason: String? = if case .unsupported(let reason) = source { reason } else { nil }
        let isEditor = source == .supported(.editorExtension)
        let pending = room.sessionId.flatMap { model.restorer.pending(sessionId: $0) }
        let showsHandover: Bool = {
            guard !busy, closeWait == nil, sourceReason == nil else { return false }
            switch pending {
            case nil: return true
            // 見送り中は、前の claude が終わらない時の逃げ道として使える時だけ出す。
            case .deferred: return disabledReason == nil
            case .judging, .waiting: return false
            }
        }()
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: pending != nil || closeWait != nil ? "arrow.clockwise.circle"
                  : room.snapshot?.entrypoint == "cli" ? "terminal" : "macwindow")
                .font(.system(size: 14))
                .foregroundStyle(ChatTheme.waiting)
            Text(summary(pending: pending, closeWait: closeWait, sourceReason: sourceReason))
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.text)
                .lineLimit(1...3)
                .truncationMode(.tail)
                .help(description(pending: pending, closeWait: closeWait, sourceReason: sourceReason, isEditor: isEditor,
                                  showsHandover: showsHandover))
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
                Text("引き継ぎ中…").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            } else if let closeWait, let sessionId = room.sessionId {
                ProgressView().controlSize(.small)
                Text(closeWait == .settling ? "再開しています…" : "閉じるのを待っています…")
                    .font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                actionButton("やめる", systemImage: "xmark", prominent: false, enabled: true,
                             help: "引き継ぎの待ちをやめます（VS Code の claude はそのまま）") {
                    model.handover.cancelCloseWait(sessionId: sessionId)
                }
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
                    if isEditor {
                        actionButton("VS Code のタブを閉じたら引き継ぐ", systemImage: "rectangle.portrait.and.arrow.right",
                                     enabled: disabledReason == nil,
                                     help: disabledReason ?? "VS Code でこの会話のタブを閉じたら、このアプリで同じ会話を再開します（VS Code の claude は止めません）") {
                            model.handover.requestOnClose(room)
                        }
                        actionButton("今すぐ止めて引き継ぐ", systemImage: "stop.circle", prominent: false, enabled: disabledReason == nil,
                                     help: disabledReason ?? "VS Code の claude を止めて、このアプリで同じ会話を再開します") {
                            model.handover.request(room)
                        }
                    } else {
                        actionButton("アプリに引き継ぐ", systemImage: "arrow.down.app", enabled: disabledReason == nil,
                                     help: disabledReason ?? "元のターミナルの claude を終了し、このアプリで同じ会話を再開します") {
                            model.handover.request(room)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { compact = $0 }
        .background(ChatTheme.externalBanner)
        .overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
    }

    private func actionButton(_ title: String, systemImage: String, prominent: Bool = true, enabled: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if !compact { Text(title) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(!enabled ? ChatTheme.tertiary : prominent ? ChatTheme.onAccent : ChatTheme.text)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(enabled && prominent ? ChatTheme.accent : ChatTheme.inputSurface))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(compact ? "\(title): \(help)" : help)
        .accessibilityLabel(title)
        .fixedSize()
    }

    /// 帯に出す短い文（詳しい説明は `description` をホバーで出す）。
    private func summary(pending: SessionRestorer.Pending?, closeWait: HandoverCloseWait.Phase?, sourceReason: String?) -> String {
        switch closeWait {
        case .waitingForClose: return "VS Code でこの会話のタブを閉じてください（閉じたら自動でアプリに引き継ぎます）。"
        case .waitingForOther(let pid): return "同じ会話が別の claude（pid \(pid)）で動いています。終わったら引き継ぎます。"
        case .settling: return "VS Code の claude が終わりました。このアプリで再開します。"
        case nil: break
        }
        switch pending {
        case .judging: return "前回アプリでホストしていた会話です。再開できるか確かめています。"
        case .waiting: return "前回アプリでホストしていた会話です。前の claude が終わったら再開します。"
        case .deferred: return "前回アプリでホストしていた会話です（再開を見送っています）。"
        case nil:
            let source = SessionHandover.sourceDescription(entrypoint: room.snapshot?.entrypoint)
            if let sourceReason { return source + "\(sourceReason)。" }
            return source + "ここから送れるのは『伝言』と権限の許可・拒否だけです。"
        }
    }

    private func description(pending: SessionRestorer.Pending?, closeWait: HandoverCloseWait.Phase?, sourceReason: String?,
                             isEditor: Bool, showsHandover: Bool) -> String {
        let limits = "ここから送れるのは『伝言』と権限の許可・拒否だけです。"
        let stopButton = isEditor ? "［今すぐ止めて引き継ぐ］" : "［アプリに引き継ぐ］"
        switch closeWait {
        case .waitingForClose:
            return "VS Code でこの会話のタブを閉じてください（閉じたら自動でアプリに引き継ぎます）。"
        case .waitingForOther(let pid):
            return "VS Code の claude は終わりましたが、同じ会話が別の claude（pid \(pid)）で動いています。そちらも終わったらアプリに引き継ぎます。"
        case .settling:
            return "VS Code の claude が終わりました。このアプリで同じ会話を再開します。"
        case nil:
            break
        }
        switch pending {
        case .judging:
            return "前回アプリでホストしていた会話です。このアプリで再開できるか確かめています。" + limits
        case .waiting:
            return "前回アプリでホストしていた会話です。前の claude が終わったら、このアプリで再開します。" + limits
        case .deferred:
            return "前回アプリでホストしていた会話です（再開を見送っています）。" + limits
                + "［再開する］で、このアプリで同じ会話を再開します。"
                + (showsHandover ? "前の claude が終わらない時は\(stopButton)で止めてから再開できます。" : "")
        case nil:
            if let sourceReason { return SessionHandover.sourceDescription(entrypoint: room.snapshot?.entrypoint) + limits + "\(sourceReason)。" }
            if isEditor {
                return SessionHandover.sourceDescription(entrypoint: room.snapshot?.entrypoint) + limits
                    + "［VS Code のタブを閉じたら引き継ぐ］は、タブを閉じた後にこのアプリで会話を再開します。"
                    + "［今すぐ止めて引き継ぐ］は VS Code の claude を止めてすぐ再開します（VS Code のタブは残るので、そこでは打たないでください）。"
            }
            return SessionHandover.sourceDescription(entrypoint: room.snapshot?.entrypoint) + limits
                + "引き継ぐと、元のターミナルの claude を終了してこのアプリで会話を再開します。"
        }
    }
}

/// ホスト中の会話と同じ会話がアプリの外で動き出した時の警告（その間は送信を止めている）。
struct ExternalDuplicateBanner: View {
    let duplicate: ExternalDuplicate

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(ChatTheme.error)
            Text(duplicate.warning)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.text)
                .lineLimit(1...3)
                .truncationMode(.tail)
                .help(duplicate.warning)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(ChatTheme.error.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
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
