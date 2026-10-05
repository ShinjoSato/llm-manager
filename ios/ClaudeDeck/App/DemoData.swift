#if DEBUG
import DeckCore
import Foundation

/// 画面の確認用のデータ（`-demo rooms` / `-demo conversation` で起動した時だけ。通信しない）。
@MainActor
enum DemoData {
    static func model(from arguments: [String]) -> AppModel? {
        guard let i = arguments.firstIndex(of: "-demo"), i + 1 < arguments.count else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        let pairing = RemotePairing(host: "192.0.2.20", port: 8767, localHostName: "demo-mac.local",
                                    fingerprint: String(repeating: "ab", count: 32), serverName: "Demo の MacBook Pro",
                                    deviceId: "demo", deviceToken: "demo", pairedAt: now - 86_400_000)
        let model = AppModel(demo: state(now: now), pairing: pairing, transcripts: ["s-mirio": transcript(now: now)],
                             open: nil)
        if arguments[i + 1] == "conversation" { model.launchRoomId = mirioRoomId }
        return model
    }

    static let mirioRoomId = "h:5D1B9C2E-7A41-4E0B-9F3A-2C8D6E1F0A11"

    static func state(now: Double) -> RemoteState {
        let input = RemoteSendState(mode: .input, disabledReason: nil)
        let blocked = RemoteSendState(mode: .input, disabledReason: "選択肢に答えると送れます")
        let relay = RemoteSendState(mode: .relay, disabledReason: nil)
        let menu = RemoteMenu(menuId: "m1", context: ["## 計画", "1. 一覧のキャッシュを足す", "2. 試験を書く"],
                              question: "Would you like to proceed?",
                              options: [RemoteMenuOption(index: 0, number: 1, label: "Yes, and auto-accept edits", detail: [], checked: nil, isSubmit: false, selectable: true),
                                        RemoteMenuOption(index: 1, number: 2, label: "Yes, and manually approve edits", detail: [], checked: nil, isSubmit: false, selectable: true),
                                        RemoteMenuOption(index: 2, number: 3, label: "No, keep planning", detail: [], checked: nil, isSubmit: false, selectable: true)],
                              cursor: 0, footer: "", tabs: nil, isMultiSelect: false, isReview: false, cancelExits: false)
        func room(_ id: String, _ kind: RemoteRoomKind, _ phase: RemoteRoomPhase, _ name: String, _ branch: String?, _ status: SessionStatus,
                  _ line: String, _ ago: Double, _ sid: String?, send: RemoteSendState, menu: RemoteMenu? = nil,
                  permissions: [PendingPermission] = []) -> RemoteRoom {
            RemoteRoom(id: id, kind: kind, phase: phase, name: name, branch: branch, status: status, line: line, activityAt: now - ago,
                       sessionId: sid, cwd: "/Users/demo/project/\(name)", ended: nil, session: nil, permissions: permissions,
                       terminalPermission: nil, menu: menu, unreadableMenu: nil, busy: false, send: send)
        }
        let permission = PendingPermission(key: "k1", requestId: "r1", sessionId: "s-infra", project: "infra", toolName: "Bash",
                                           description: "terraform plan を実行", inputPreview: "terraform plan -out=tfplan", askedAt: now - 20_000)
        return RemoteState(rooms: [
            room(mirioRoomId, .hosted, .attention, "mirio", "develop", .waiting, "計画を確認してください", 40_000, "s-mirio", send: blocked, menu: menu),
            room("e:s-infra", .external, .attention, "infra", "main", .permission, "Bash: terraform plan", 20_000, "s-infra", send: relay,
                 permissions: [permission]),
            room("h:8C0D1E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F", .hosted, .active, "sandora", "feature/88", .working, "Edit: ChatView.swift", 5_000, "s-sandora", send: input),
            room("e:s-blog", .external, .idle, "blog", "main", .idle, "記事の下書きを書きました", 3_600_000, "s-blog", send: relay),
            room("h:1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", .hosted, .idle, "ai-manager", "feature/121", .stopped, "", 86_400_000 * 2, "s-ai", send: input),
        ], usage: nil, monitoring: true)
    }

    static func transcript(now: Double) -> [TranscriptItem] {
        func item(_ id: String, _ kind: TranscriptItemKind, _ text: String?, ago: Double, tool: TranscriptTool? = nil,
                  parent: String? = nil) -> TranscriptItem {
            TranscriptItem(id: id, kind: kind, at: now - ago, text: text, tool: tool, parentId: parent)
        }
        return [
            item("u1", .user, "一覧の読み込みが遅いので、キャッシュを足して速くしたい。まず計画を立てて。", ago: 300_000),
            item("a1", .assistant, "調べました。遅いのは **毎回すべての行を作り直している** ためです。\n\n| 対象 | 今 | 改善後 |\n|---|---|---|\n| 初回 | 1.2 秒 | 1.2 秒 |\n| 2 回目以降 | 1.1 秒 | 0.1 秒 |\n\n次の手順で進めます:\n\n1. `RoomListCache` を足す\n2. 試験を書く", ago: 120_000),
            item("t1", .tool, nil, ago: 110_000, tool: TranscriptTool(name: "Read", description: nil, target: "Sources/RoomList.swift"), parent: "a1"),
            item("t2", .tool, nil, ago: 100_000, tool: TranscriptTool(name: "Grep", description: nil, target: "makeRows"), parent: "a1"),
            item("a2", .assistant, "計画をまとめました。進めてよいか選んでください。", ago: 45_000),
        ]
    }
}
#endif
