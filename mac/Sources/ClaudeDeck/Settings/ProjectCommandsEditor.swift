import AppKit
import MonitorKit
import SwiftUI

/// プロジェクトの実行コマンドの編集。全行が正しい間だけ保存し、名前とコマンドが両方空の行は数えない（追加した直後の行で他の行の保存を止めない）。
struct ProjectCommandsEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var rows: [Row] = []
    @State private var problems: [[String]] = []
    /// 最後に設定から欄へ入れた値。利用者が触るまでは空白を落としただけの差を書き直さないために持つ。
    @State private var loaded: [ProjectCommand] = []
    @FocusState private var focused: Field?

    /// 画面で行を見分けるためだけの印（ファイルには書かない）。
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var command: String
        var icon: String?

        init(_ command: ProjectCommand) {
            name = command.name
            self.command = command.command
            icon = command.icon
        }

        var raw: ProjectCommand { ProjectCommand(name: name, command: command, icon: icon) }

        /// 保存する形（名前は前後の空白、コマンドは前後の空行を落とす）。
        var trimmed: ProjectCommand {
            ProjectCommand(name: name.trimmingCharacters(in: .whitespaces),
                           command: command.trimmingCharacters(in: .newlines), icon: icon)
        }
    }

    private enum Field: Hashable {
        case name(UUID), command(UUID)
    }

    private var key: String { SettingsStore.projectKey(id: project.id, field: "commands") }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("実行コマンドはありません").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("名前", text: binding(index, \.name, fallback: ""), prompt: Text("名前"))
                            .settingsField { store.flushPending() }
                            .focused($focused, equals: .name(row.id))
                            .frame(width: 160)
                        Picker("アイコン", selection: binding(index, \.icon, fallback: nil)) {
                            Label("既定", systemImage: ProjectCommands.defaultSymbol).tag(String?.none)
                            ForEach(symbolChoices(current: row.icon), id: \.self) { symbol in
                                Label(symbol, systemImage: symbol).tag(String?.some(symbol))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .help("見出しのボタンのアイコン")
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("上へ")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == rows.count - 1).help("下へ")
                        Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }
                            .help("このコマンドを削除")
                    }
                    .buttonStyle(.borderless)
                    TextField("コマンド", text: binding(index, \.command, fallback: ""), prompt: Text("npm run dev"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...6)
                        .focused($focused, equals: .command(row.id))
                    if problems.indices.contains(index) {
                        SettingsProblems(problems: problems[index])
                    }
                }
            }
            Button {
                let row = Row(ProjectCommand(name: "", command: ""))
                rows.append(row)
                focused = .name(row.id)
            } label: { Label("コマンドを追加", systemImage: "plus") }
        } header: {
            Text("実行コマンド")
        } footer: {
            Text("このプロジェクトのルームの見出しにボタンで出し、押すとルームの「ターミナル」のタブ（ルームのフォルダのログインシェル）で実行します。複数行も 1 回の貼り付けとして入れて Enter を送ります。何かが動いている最中・打ちかけの入力がある時・ここ以外で書き換わった本文を初めて送る時は確認を出します。claude の headless 起動（-p / --print）は登録できません。名前はプロジェクトの中で重ねられません（\(ProjectCommands.nameLimit) 文字まで）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load(project.commands) }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す。自分の保存では値が一致するので何もしない）。
        .onChange(of: project.commands) { _, commands in
            guard commands != draft else { return }
            store.cancelPending(key: key)
            load(commands)
        }
        .onChange(of: rows) { commit() }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
    }

    /// 選べるアイコン（設定に手で書いた一覧に無い名前も、その行では選べるように残す）。
    private func symbolChoices(current: String?) -> [String] {
        var choices = ProjectCommands.symbolChoices.filter { $0 != ProjectCommands.defaultSymbol }
        if let current, !current.isEmpty, current != ProjectCommands.defaultSymbol, !choices.contains(current) { choices.append(current) }
        return choices
    }

    /// 行の欄。消した直後の描き直しで添字が外れていれば `fallback` を見せ、書き込みは捨てる。
    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<Row, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { rows.indices.contains(index) ? rows[index][keyPath: keyPath] : fallback },
                set: { if rows.indices.contains(index) { rows[index][keyPath: keyPath] = $0 } })
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
        store.flushPending()
    }

    private func remove(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
        store.flushPending()
    }

    /// 欄の今の中身を行ごとに。名前とコマンドが両方空の行は nil。
    private var trimmedRows: [ProjectCommand?] {
        rows.map { row in
            let command = row.trimmed
            return command.name.isEmpty && command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command
        }
    }

    private var trimmed: [ProjectCommand] { trimmedRows.compactMap { $0 } }

    /// 行ごとの問題（空の行は問題なし）。並びは `rows` と同じ。
    private var rowProblems: [[String]] {
        var problems = SettingsValidation.projectCommandRowProblems(trimmed).makeIterator()
        return trimmedRows.map { command in
            guard command != nil else { return [] }
            return problems.next() ?? []
        }
    }

    /// 全行が正しい時だけ保存する形。どこかが途中なら nil。
    private var draft: [ProjectCommand]? {
        rowProblems.allSatisfy(\.isEmpty) ? trimmed : nil
    }

    private func load(_ commands: [ProjectCommand]) {
        rows = commands.map(Row.init)
        loaded = rows.map(\.raw)
        // 手で書いた不正な行も、開いた時から理由を出す。
        problems = rowProblems
    }

    private func commit() {
        problems = rowProblems
        // 設定から入れたままなら予約しない（開いただけで書き直さない）。
        guard rows.map(\.raw) != loaded else { return }
        let commands = trimmed
        guard commands != project.commands else {
            store.cancelPending(key: key)
            return
        }
        guard problems.allSatisfy(\.isEmpty) else {
            store.cancelPending(key: key)
            return
        }
        // 設定画面で書いた本文は、見ながら書いたものなので確かめ済みにする。
        CommandApprovalStore.shared.approve(commands)
        store.scheduleProject(id: project.id, field: "commands", \.commands, commands)
    }
}
