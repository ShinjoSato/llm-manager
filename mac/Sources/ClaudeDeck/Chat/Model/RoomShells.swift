import Foundation
import Observation
import MonitorKit

/// 実行コマンドを送る前の確認（出したウィンドウで答える）。
struct ShellConfirmation: Identifiable {
    let id = UUID()
    let room: RoomID
    /// 押したウィンドウ（nil はメイン）。
    let window: UUID?
    let command: ProjectCommand
    let reasons: [ShellSendReason]
}

/// 確かめた実行コマンドの本文（hash だけをアプリの手元に覚え、settings.json には書かない）。
@MainActor
final class CommandApprovalStore {
    static let shared = CommandApprovalStore()
    private let key = "ProjectCommandApprovals"
    private let limit = 500
    private var keys: [String]

    init() {
        keys = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isApproved(_ command: ProjectCommand) -> Bool {
        keys.contains(ProjectCommands.approvalKey(command))
    }

    func approve(_ commands: [ProjectCommand]) {
        var changed = false
        for command in commands {
            let hash = ProjectCommands.approvalKey(command)
            guard !keys.contains(hash) else { continue }
            keys.append(hash)
            changed = true
        }
        guard changed else { return }
        if keys.count > limit { keys.removeFirst(keys.count - limit) }
        UserDefaults.standard.set(keys, forKey: key)
    }
}

/// ルームのターミナル（ルームごとに 1 つのシェル）と、ウィンドウごとに見ているタブ・ルームごとの最後のタブ。
@MainActor
@Observable
final class RoomShells {
    /// メインのウィンドウの印（別ウィンドウはそのウィンドウの印を使う）。
    static let mainWindow = UUID()
    /// 外部ルームが消えた後、同じフォルダのルームが現れたらシェルを付け替える猶予。
    static let adoptWindow: TimeInterval = 120

    private struct TabKey: Hashable {
        let window: UUID
        let room: RoomID
    }

    /// 一覧から消えた外部ルームのシェル（付け替え待ち・動いているので残しているもの）。
    struct Orphan {
        let shell: RoomShell
        let oldRoom: RoomID
        let name: String
        let since: Date
        /// 消えた時にもうあったルーム（そこへは付け替えない）。
        let existing: Set<RoomID>
    }

    private(set) var shells: [RoomID: RoomShell] = [:]
    private(set) var tabs = RoomTabMemory<RoomID>()
    private var viewTabs: [TabKey: RoomTab] = [:]
    private(set) var orphans: [Orphan] = []
    var confirmation: ShellConfirmation?

    /// 止める途中のもの（閉じた直後・シェルが自分で終わった後）。アプリの終了でも待つ。
    @ObservationIgnored private var stopping: [ShellSessionStop] = []
    @ObservationIgnored private var lastRunWindow: [RoomID: UUID?] = [:]
    @ObservationIgnored private var sweepTimer: Timer?
    /// タブを押した時にまだシェルが無かったルーム（起動したら入力の先にする）。
    @ObservationIgnored private var focusOnOpen: Set<RoomID> = []

    /// ターミナルを開けるフォルダか（cwd が分かり、ディレクトリとしてある）。
    static func canOpen(_ cwd: String) -> Bool {
        guard cwd.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - タブ

    /// そのウィンドウで見ているタブ（まだ選んでいなければルームの最後の選択）。
    func tab(for room: RoomID, window: UUID?) -> RoomTab {
        viewTabs[TabKey(window: window ?? Self.mainWindow, room: room)] ?? tabs.tab(for: room)
    }

    /// 会話を出し始めた時。ルームの最後の選択から始める。
    func beginShowing(_ room: RoomID, window: UUID?) {
        viewTabs[TabKey(window: window ?? Self.mainWindow, room: room)] = tabs.tab(for: room)
    }

    /// タブを押した。ターミナルなら端末を入力の先にする。
    func select(_ tab: RoomTab, for room: RoomID, window: UUID?) {
        viewTabs[TabKey(window: window ?? Self.mainWindow, room: room)] = tab
        tabs.set(tab, for: room)
        guard tab == .terminal else { return }
        if let shell = shells[room] { shell.requestFocus() } else { focusOnOpen.insert(room) }
    }

    /// 別ウィンドウを閉じた。そのウィンドウのタブを忘れ、端末を残りの側へ戻す。
    func windowClosed(_ token: UUID) {
        viewTabs = viewTabs.filter { $0.key.window != token }
        for shell in shells.values { shell.release(token) }
    }

    func shell(for id: RoomID) -> RoomShell? { shells[id] }

    /// タブを開いた時。シェルが無ければ作って起動する（終わったシェルは「もう一度開く」まで起こさない）。
    func open(_ room: Room) {
        guard shells[room.id] == nil, Self.canOpen(room.cwd) else { return }
        let shell = makeShell(cwd: room.cwd)
        shells[room.id] = shell
        shell.start()
        if focusOnOpen.remove(room.id) != nil { shell.requestFocus() }
    }

    private func makeShell(cwd: String) -> RoomShell {
        let shell = RoomShell(cwd: cwd)
        shell.onNeedsConfirmation = { [weak self, weak shell] command, reasons in
            guard let self, let shell, let room = self.shells.first(where: { $0.value === shell })?.key else { return }
            self.confirmation = ShellConfirmation(room: room, window: self.lastRunWindow[room] ?? nil, command: command, reasons: reasons)
        }
        shell.onStopStarted = { [weak self] stop in self?.track(stop) }
        return shell
    }

    // MARK: - 実行コマンド

    /// 押した時。確かめることがあれば確認を出し、無ければ送る。送れなければ理由を返す。
    func request(_ command: ProjectCommand, in room: Room, window: UUID?) -> String? {
        if let refusal = Self.refusal(command, cwd: room.cwd) { return refusal }
        let approved = CommandApprovalStore.shared.isApproved(command)
        let reasons = shells[room.id]?.sendReasons(approved: approved) ?? (approved ? [] : [.notApproved])
        guard reasons.isEmpty else {
            confirmation = ShellConfirmation(room: room.id, window: window, command: command, reasons: reasons)
            return nil
        }
        return run(command, in: room, window: window, confirmed: false)
    }

    /// 確認で「送る」を押した。
    func confirm(_ confirmation: ShellConfirmation, room: Room?) -> String? {
        self.confirmation = nil
        guard let room, room.id == confirmation.room else { return "ルームが閉じられたため、送りませんでした。" }
        if let refusal = Self.refusal(confirmation.command, cwd: room.cwd) { return refusal }
        CommandApprovalStore.shared.approve([confirmation.command])
        return run(confirmation.command, in: room, window: confirmation.window, confirmed: true)
    }

    /// 送らない理由（ターミナルを開けない・headless の claude 等の検証に通らない）。
    private static func refusal(_ command: ProjectCommand, cwd: String) -> String? {
        guard canOpen(cwd) else { return "このルームのフォルダが分からないため、ターミナルで実行できません。" }
        let problems = SettingsValidation.projectCommandProblems(command)
        guard problems.isEmpty else { return "「\(command.name)」は送れません: \(problems.joined(separator: " / "))" }
        return nil
    }

    private func run(_ command: ProjectCommand, in room: Room, window: UUID?, confirmed: Bool) -> String? {
        lastRunWindow[room.id] = window
        viewTabs[TabKey(window: window ?? Self.mainWindow, room: room.id)] = .terminal
        tabs.set(.terminal, for: room.id)
        let shell = shells[room.id] ?? makeShell(cwd: room.cwd)
        shells[room.id] = shell
        guard shell.run(command, confirmed: confirmed) else {
            if case .failed(let reason) = shell.phase { return "「\(command.name)」を実行できませんでした: \(reason)" }
            return "「\(command.name)」を実行できませんでした。"
        }
        return nil
    }

    // MARK: - 止める・移す

    /// ターミナルで何かが動いているルーム（閉じる・終了の確認に使う）。
    var busyRooms: [RoomID] { shells.filter { $0.value.isBusy }.map(\.key) }

    /// ルームの無くなったシェルで、まだ何かが動いているもの（終了の確認に使う）。
    var busyOrphanNames: [String] { orphans.filter { $0.shell.isBusy }.map(\.name) }

    /// ルームを閉じた。シェルをセッションごと止める（残りの手順は裏で進める）。
    func close(_ id: RoomID) {
        tabs.forget(id)
        viewTabs = viewTabs.filter { $0.key.room != id }
        lastRunWindow[id] = nil
        if confirmation?.room == id { confirmation = nil }
        guard let shell = shells.removeValue(forKey: id) else { return }
        stop(shell)
    }

    private func stop(_ shell: RoomShell) {
        guard let stop = shell.stop() else { return }
        track(stop)
    }

    private func track(_ stop: ShellSessionStop) {
        stopping.append(stop)
        Task { [weak self] in
            await stop.finish()
            self?.stopping.removeAll { $0 === stop }
        }
    }

    /// 引き継ぎで外部ルームからホスト中のルームへ移った。シェルとタブを移し先へ渡す（移し先に既にあればそちらを残す）。
    func move(from old: RoomID, to new: RoomID) {
        guard old != new else { return }
        tabs.move(from: old, to: new)
        viewTabs = Dictionary(viewTabs.map { key, tab in (key.room == old ? TabKey(window: key.window, room: new) : key, tab) },
                              uniquingKeysWith: { _, moved in moved })
        if let window = lastRunWindow.removeValue(forKey: old) { lastRunWindow[new] = window }
        guard let shell = shells.removeValue(forKey: old) else { return }
        if shells[new] == nil {
            shells[new] = shell
        } else {
            stop(shell)
        }
    }

    /// 一覧の変化に合わせる。消えた外部ルームのシェルはすぐ止めず、同じフォルダのルームが猶予の内に現れたら付け替える。
    func reconcile(rooms: [Room], isHandingOver: (String) -> Bool, now: Date = Date()) {
        let alive = Set(rooms.map(\.id))
        for (id, shell) in shells {
            guard case .external(let sessionId) = id, !alive.contains(id), !isHandingOver(sessionId) else { continue }
            shells[id] = nil
            viewTabs = viewTabs.filter { $0.key.room != id }
            if confirmation?.room == id { confirmation = nil }
            if shell.isRunning {
                orphans.append(Orphan(shell: shell, oldRoom: id, name: (shell.cwd as NSString).lastPathComponent, since: now, existing: alive))
            } else {
                tabs.forget(id)
                _ = shell.stop()
            }
        }
        for room in rooms where shells[room.id] == nil {
            guard let index = orphans.firstIndex(where: { orphan in
                orphan.shell.cwd == room.cwd && !orphan.existing.contains(room.id) && now.timeIntervalSince(orphan.since) < Self.adoptWindow
            }) else { continue }
            let orphan = orphans.remove(at: index)
            shells[room.id] = orphan.shell
            tabs.move(from: orphan.oldRoom, to: room.id)
            if let window = lastRunWindow.removeValue(forKey: orphan.oldRoom) { lastRunWindow[room.id] = window }
        }
        sweepOrphans(now: now)
    }

    /// 猶予を過ぎたシェル: 何も動いていなければ止め、動いていれば残す（アプリの終了で止める）。
    private func sweepOrphans(now: Date = Date()) {
        var kept: [Orphan] = []
        for orphan in orphans {
            if !orphan.shell.isRunning {
                tabs.forget(orphan.oldRoom)
                _ = orphan.shell.stop()
            } else if now.timeIntervalSince(orphan.since) >= Self.adoptWindow, !orphan.shell.isBusy {
                tabs.forget(orphan.oldRoom)
                stop(orphan.shell)
            } else {
                kept.append(orphan)
            }
        }
        orphans = kept
        updateSweepTimer()
    }

    private func updateSweepTimer() {
        guard !orphans.isEmpty else {
            sweepTimer?.invalidate()
            sweepTimer = nil
            return
        }
        guard sweepTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.sweepOrphans()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    /// アプリの終了時。全シェルにセッションごと SIGHUP を送って PTY を閉じ、止める途中のものと合わせて返す（`ShellSessionStop.finishAllBlocking` で待つ）。
    func beginStopAll() -> [ShellSessionStop] {
        let all = Array(shells.values) + orphans.map(\.shell)
        shells = [:]
        orphans = []
        updateSweepTimer()
        return all.compactMap { $0.stop() } + stopping.filter { !$0.isFinished }
    }
}
