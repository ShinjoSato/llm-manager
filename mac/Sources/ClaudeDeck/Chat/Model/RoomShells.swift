import Foundation
import Observation
import MonitorKit

/// ルームのターミナル（ルームごとに 1 つのシェル）と、ルームごとに最後に開いていたタブ。
@MainActor
@Observable
final class RoomShells {
    private(set) var shells: [RoomID: RoomShell] = [:]
    private(set) var tabs = RoomTabMemory<RoomID>()

    /// ターミナルを開けるフォルダか（cwd が分かり、ディレクトリとしてある）。
    static func canOpen(_ cwd: String) -> Bool {
        guard cwd.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func tab(for id: RoomID) -> RoomTab { tabs.tab(for: id) }

    func select(_ tab: RoomTab, for id: RoomID) {
        tabs.set(tab, for: id)
    }

    func shell(for id: RoomID) -> RoomShell? { shells[id] }

    /// タブを開いた時。シェルが無ければ作って起動する（終わったシェルは「もう一度開く」まで起こさない）。
    func open(_ room: Room) {
        guard shells[room.id] == nil, Self.canOpen(room.cwd) else { return }
        let shell = RoomShell(cwd: room.cwd)
        shells[room.id] = shell
        shell.start()
    }

    /// 送る前に確かめるか（動いているシェルで、プロンプトに戻っていると分からない時）。
    func needsConfirmation(for room: Room) -> Bool {
        guard let shell = shells[room.id], shell.isRunning else { return false }
        return shell.foreground.needsConfirmation
    }

    /// 実行コマンドをルームのターミナルで流す（タブを切り替え、シェルが無ければ起動する）。送れなければ理由を返す。
    func run(_ command: ProjectCommand, in room: Room) -> String? {
        guard Self.canOpen(room.cwd) else { return "このルームのフォルダが分からないため、ターミナルで実行できません。" }
        tabs.set(.terminal, for: room.id)
        let shell = shells[room.id] ?? RoomShell(cwd: room.cwd)
        shells[room.id] = shell
        guard shell.run(command.command) else {
            if case .failed(let reason) = shell.phase { return "「\(command.name)」を実行できませんでした: \(reason)" }
            return "「\(command.name)」を実行できませんでした。"
        }
        return nil
    }

    /// ルームを閉じた。シェルをセッションごと止める（残りの手順は裏で進める）。
    func close(_ id: RoomID) {
        tabs.forget(id)
        guard let shell = shells.removeValue(forKey: id), let stop = shell.stop() else { return }
        Task.detached { await stop.finish() }
    }

    /// 引き継ぎで外部ルームからホスト中のルームへ移った。シェルとタブを移し先へ渡す（移し先に既にあればそちらを残す）。
    func move(from old: RoomID, to new: RoomID) {
        guard old != new else { return }
        tabs.move(from: old, to: new)
        guard let shell = shells.removeValue(forKey: old) else { return }
        if shells[new] == nil {
            shells[new] = shell
        } else if let stop = shell.stop() {
            Task.detached { await stop.finish() }
        }
    }

    /// 一覧から消えた外部ルームのシェルを止める（引き継ぎの途中のものは移すので残す）。
    func closeVanishedExternalRooms(alive: Set<RoomID>, isHandingOver: (String) -> Bool) {
        let stale = shells.keys.filter { id in
            guard case .external(let sessionId) = id else { return false }
            return !alive.contains(id) && !isHandingOver(sessionId)
        }
        for id in stale { close(id) }
    }

    /// アプリの終了時。全シェルにセッションごと SIGHUP を送って PTY を閉じる。残りの手順は `ShellSessionStop.finishAllBlocking` で待つ。
    func beginStopAll() -> [ShellSessionStop] {
        let stops = shells.values.compactMap { $0.stop() }
        shells = [:]
        return stops
    }
}
