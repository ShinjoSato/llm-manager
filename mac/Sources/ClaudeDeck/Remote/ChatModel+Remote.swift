import Foundation
import MonitorKit

/// iPhone からの操作。どれも画面のカード・入力欄と同じ経路（照合・二度押し防止・選択待ちでの停止）を通し、mac には警告を出さない。
extension ChatModel: RemoteControl {
    func remoteState() -> RemoteState {
        // mac の検索欄の絞り込みは iPhone に持ち込まない。
        let keys = rooms.map { room in
            RoomKey(id: RemoteRoomID(room.id).string, name: room.name, status: room.status, activityAt: room.activityAt, searchText: "")
        }
        let byId = Dictionary(rooms.map { (RemoteRoomID($0.id).string, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = RoomGrouping.group(keys).flatMap { group in group.ids.compactMap { byId[$0] } }
        return RemoteState(rooms: ordered.map(remoteRoom), usage: store.usage, monitoring: store.connection.isConnected)
    }

    private func remoteRoom(_ room: Room) -> RemoteRoom {
        let permissions = monitorPermissions(for: room)
        let cards: RemoteRoomCards
        var busy = permissions.contains { busyPermissionKeys.contains($0.key) }
        let send: RemoteSendState
        var ended: String?
        if let session = room.hosted {
            cards = RemoteRoomCards(channelsPending: !permissions.isEmpty, card: session.terminalCard,
                                    generation: session.promptTracker.generation)
            busy = busy || busyPermissionKeys.contains(Self.ptyPermissionKey(session)) || busyPermissionKeys.contains(Self.ptyMenuKey(session))
            send = RemoteSendState(mode: .input, disabledReason: Self.inputDisabledReason(for: room) ?? (session.isSending ? "送信中…" : nil))
            switch session.end {
            case .exited: ended = "exited"
            case .limitReached: ended = "limitReached"
            case .launchFailed: ended = "launchFailed"
            case nil: ended = nil
            }
        } else {
            cards = RemoteRoomCards(channelsPending: false, card: nil, generation: 0)
            send = RemoteSendState(mode: .relay, disabledReason: inputDisabledReason(for: room))
        }
        return RemoteRoom(id: RemoteRoomID(room.id).string, kind: room.hosted == nil ? .external : .hosted,
                          phase: RemoteRoomPhase(RoomPhase(status: room.status)), name: room.name, branch: room.branch,
                          status: room.status, line: room.line, activityAt: room.activityAt, sessionId: room.sessionId,
                          cwd: room.cwd, ended: ended, session: room.snapshot, permissions: permissions,
                          terminalPermission: cards.terminalPermission, menu: cards.menu, unreadableMenu: cards.unreadableMenu,
                          busy: busy, send: send)
    }

    private func room(_ roomId: String) -> Room? {
        guard let id = RemoteRoomID(roomId) else { return nil }
        return rooms.first { RemoteRoomID($0.id) == id }
    }

    /// 照合に使う今の端末の様子（一覧のカードと同じ組み立て）。
    private func terminalContext(_ room: Room, _ session: HostedSession) -> RemoteTerminalContext {
        RemoteTerminalContext(card: session.terminalCard, tracker: session.promptTracker,
                              channelsPending: !monitorPermissions(for: room).isEmpty)
    }

    private static let roomNotFound = RemoteActionResult.failure("not_found", "ルームが見つかりません。閉じられた可能性があります。")
    private static let notHosted = RemoteActionResult.failure("unavailable", "このルームは mac アプリでホストしていないため、端末の操作はできません。")

    // MARK: - 権限

    func remoteDecide(key: String, decision: PermissionDecision) async -> RemoteActionResult {
        await decide(key: key, decision)
    }

    func remoteAnswerTerminalPermission(roomId: String, promptId: String, decision: PermissionDecision) async -> RemoteActionResult {
        guard let room = room(roomId) else { return Self.roomNotFound }
        guard let session = room.hosted else { return Self.notHosted }
        switch RemoteChecks.terminalPermission(promptId: promptId, in: terminalContext(room, session)) {
        case .failure(let result): return result
        case .success(let prompt): return answerOnTerminal(session, prompt: prompt, allow: decision == .allow, report: false)
        }
    }

    // MARK: - 選択肢

    func remoteAnswerMenu(roomId: String, request: RemoteMenuAnswerRequest) async -> RemoteActionResult {
        guard let room = room(roomId) else { return Self.roomNotFound }
        guard let session = room.hosted else { return Self.notHosted }
        switch RemoteChecks.menuAnswer(request, in: terminalContext(room, session)) {
        case .failure(let result):
            return result
        case .success(let (menu, action)):
            let choice: Int?
            switch action {
            case .choose(let index): choice = index
            case .cancel: choice = nil
            }
            return await RemoteOperation.wait { done in
                answerMenu(session, menu: menu, choice: choice, report: false) { done($0) }
            }
        }
    }

    func remoteMoveMenuTab(roomId: String, request: RemoteMenuTabRequest) async -> RemoteActionResult {
        guard let room = room(roomId) else { return Self.roomNotFound }
        guard let session = room.hosted else { return Self.notHosted }
        switch RemoteChecks.menuTab(request, in: terminalContext(room, session)) {
        case .failure(let result):
            return result
        case .success(let menu):
            let direction: MenuTabMover.Direction = request.direction == .next ? .next : .previous
            return await RemoteOperation.wait { done in
                moveMenuTab(session, menu: menu, direction: direction, report: false) { done($0) }
            }
        }
    }

    func remoteDismissMenu(roomId: String, request: RemoteMenuDismissRequest) async -> RemoteActionResult {
        guard let room = room(roomId) else { return Self.roomNotFound }
        guard let session = room.hosted else { return Self.notHosted }
        switch RemoteChecks.menuDismiss(request, in: terminalContext(room, session)) {
        case .failure(let result): return result
        case .success(let menu): return cancelUnreadableMenu(session, menu: menu, report: false)
        }
    }

    // MARK: - 送信

    func remoteSendMessage(roomId: String, text: String) async -> RemoteActionResult {
        guard let room = room(roomId) else { return Self.roomNotFound }
        guard let session = room.hosted else { return await relayFromRemote(text, to: room) }
        if let reason = Self.inputDisabledReason(for: room) {
            return .failure(RemoteChecks.sendBlockedCode(ended: session.end != nil, inputBlock: session.inputBlock), reason)
        }
        guard !session.isSending else { return .failure("busy", "前の送信が終わっていません。少し待ってから送ってください。") }
        // mac の入力欄の書きかけ・添付には触れない（iPhone の本文だけを送る）。
        return await RemoteOperation.wait { done in
            let result = session.send(text) { completion in done(Self.result(of: completion)) }
            switch result {
            case .started:
                break
            case .leftover:
                done(.failure("leftover", "端末側の入力欄に前回の本文が残っているようです。"
                    + "このままもう一度送ると、残っているものの後ろにつながって送られます。"))
            case .blocked(.permission):
                done(.failure("blocked_permission", "権限の確認に答えてから送ってください（今 Enter を送ると確認への「Yes」になります）。"))
            case .blocked(.menu):
                done(.failure("blocked_menu", "選択肢が出ているため送りませんでした（今 Enter を送るとその選択が確定します）。選択肢に答えてください。"))
            case .busy:
                done(.failure("busy", "前の送信が終わっていません。少し待ってから送ってください。"))
            case .empty:
                done(.failure("invalid", "本文が空です。"))
            case nil:
                done(.failure("ended", "claude は動いていません。"))
            }
        }
    }

    static func result(of completion: SendCompletion) -> RemoteActionResult {
        switch completion {
        case .submitted:
            return .success("submitted")
        case .abortedBeforeBody:
            return .failure("aborted", "送信の途中で選択肢が出たため、本文を貼る前に取りやめました。")
        case .abortedAfterBody:
            return .failure("aborted", "送信の途中で選択肢が出たため、本文を貼った後、Enter を押さずに取りやめました。"
                + "端末側の入力欄に本文が残っています。選択肢に答えた後に送ると、残っている本文とつながって送られます。")
        case .ended:
            return .failure("ended", "claude が終了したため送れませんでした。")
        }
    }

    /// 外部セッションへの伝言（画面の伝言と同じく、送った分は点線の吹き出しで mac にも出る）。
    private func relayFromRemote(_ text: String, to room: Room) async -> RemoteActionResult {
        guard let sessionId = room.sessionId else { return Self.roomNotFound }
        if let reason = inputDisabledReason(for: room) { return .failure("unavailable", reason) }
        let body = RelayNotes.normalized(text)
        guard !body.isEmpty else { return .failure("invalid", "本文が空です。") }
        let note = addRelayNote(body, to: sessionId)
        if let reason = await deliverRelay(note, to: sessionId) {
            return .failure("failed", "伝言を送れませんでした: \(reason)")
        }
        return .success("relayed")
    }
}

extension RemoteRoomID {
    init(_ id: RoomID) {
        switch id {
        case .hosted(let uuid): self = .hosted(uuid)
        case .external(let sessionId): self = .external(sessionId)
        }
    }
}
