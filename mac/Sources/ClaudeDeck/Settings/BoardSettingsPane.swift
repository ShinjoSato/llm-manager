import MonitorKit
import SwiftUI

/// 横断ボード（リポジトリに紐づかないボード）の一覧。欄が正しい間だけ保存する（settings.json に不正な値を残さない）。
struct BoardSettingsPane: View {
    let store: SettingsStore
    @State private var adding = false

    static let symbol = "rectangle.split.3x1"
    static let info = "複数のリポジトリをまたぐ GitHub Project のボードなど、プロジェクトに紐づかないもの（settings.json の boards）。アプリの画面には出さず、Claude が開発状況を見る時に読みます。プロジェクトごとのボードは各プロジェクトの紐づけの「GitHub」で設定します。"

    var body: some View {
        Form {
            Section {
                if store.settings.boards.isEmpty && !adding {
                    Text("横断ボードはありません").foregroundStyle(.tertiary)
                }
                ForEach(store.settings.boards) { board in
                    BoardRow(store: store, board: board)
                }
                if adding {
                    NewBoardEditor(store: store) { adding = false }
                } else {
                    Button { adding = true } label: { Label("ボードを追加", systemImage: "plus") }
                }
            } header: {
                SettingsSectionHeader(title: "横断ボード", info: Self.info)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.isEditable)
    }
}

/// 1 ボード 1 行（名前・`owner #N`・削除）。開くと欄を出す。欄の中身は行で持つので、閉じても途中の入力は残る。
private struct BoardRow: View {
    let store: SettingsStore
    let board: GitHubBoard
    @State private var name = ""
    @State private var owner = ""
    @State private var number = ""
    @State private var problems: [String] = []
    @State private var expanded = false
    @FocusState private var focused: BoardField?

    private var key: String { SettingsStore.boardKey(id: board.id) }
    private var draft: GitHubBoard { GitHubBoard.draft(name: name, owner: owner, number: number) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                BoardFieldRows(name: $name, owner: $owner, number: $number, focused: $focused) { store.flushPending() }
                SettingsProblems(problems: problems)
            }
            .padding(.leading, 26)
            .padding(.vertical, 4)
        } label: {
            label
        }
        .onAppear { load(board) }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す。自分の保存では値が一致するので何もしない）。
        .onChange(of: board) { _, value in
            guard value != draft else { return }
            store.cancelPending(key: key)
            load(value)
        }
        .onChange(of: name) { commit() }
        .onChange(of: owner) { commit() }
        .onChange(of: number) { commit() }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: BoardSettingsPane.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(board.name).lineLimit(1)
                Text(LinkageSummary.board(board))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(role: .destructive) { store.removeBoard(id: board.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("このボードを削除")
            }
            if !expanded, !problems.isEmpty {
                Text("保存できない入力があります（開いて直してください）")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            }
        }
    }

    private func load(_ value: GitHubBoard) {
        name = value.name
        owner = value.owner
        number = String(value.number)
        problems = []
    }

    private func commit() {
        let value = draft
        problems = SettingsValidation.boardProblems(value, among: store.settings.boards, excluding: board.id)
        // 保存できない間と、開いた・読み込んだだけ（今の値と同じ）の間は書かない。
        guard problems.isEmpty, value != board else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleBoard(id: board.id, value)
    }
}

/// 新しいボードの欄。正しく埋まったら「追加」で足す。
private struct NewBoardEditor: View {
    let store: SettingsStore
    let onDone: () -> Void
    @State private var name = ""
    @State private var owner = ""
    @State private var number = ""
    @FocusState private var focused: BoardField?

    private var draft: GitHubBoard { GitHubBoard.draft(name: name, owner: owner, number: number) }

    private var problems: [String] {
        if name.isEmpty && owner.isEmpty && number.isEmpty { return [] }
        return SettingsValidation.boardProblems(draft, among: store.settings.boards, excluding: nil)
    }

    private var canAdd: Bool { !name.isEmpty && !owner.isEmpty && !number.isEmpty && problems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 18)
                Text("新しいボード")
            }
            VStack(alignment: .leading, spacing: 6) {
                BoardFieldRows(name: $name, owner: $owner, number: $number, focused: $focused) { add() }
                SettingsProblems(problems: problems)
            }
            .padding(.leading, 26)
            HStack {
                Spacer()
                Button("キャンセル", action: onDone)
                Button("追加", action: add)
                    .disabled(!canAdd)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            // 欄が描かれてから移す。
            DispatchQueue.main.async { focused = .name }
        }
    }

    private func add() {
        guard canAdd else { return }
        store.addBoard(draft)
        onDone()
    }
}

private enum BoardField: Hashable { case name, owner, number }

/// ボードの欄を 1 行 1 項目で。
private struct BoardFieldRows: View {
    @Binding var name: String
    @Binding var owner: String
    @Binding var number: String
    var focused: FocusState<BoardField?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        row("名前", prompt: "overview", text: $name, field: .name, info: nil)
        row("owner", prompt: "ユーザーか Organization", text: $owner, field: .owner,
            info: "ボードを持つ GitHub のユーザーか Organization の名前。英数字と途中のハイフンで 39 文字まで。")
        row("Project 番号", prompt: "5", text: $number, field: .number,
            info: "ボードの URL（…/projects/N）の末尾の数字。1 以上。GitHub 上に実在するかは確かめません。")
    }

    private func row(_ title: String, prompt: String, text: Binding<String>, field: BoardField, info: String?) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                if let info { InfoButton(text: info) }
            }
            .frame(width: 110, alignment: .leading)
            TextField(title, text: text, prompt: Text(prompt))
                .settingsField(onSubmit: onSubmit)
                .focused(focused, equals: field)
                .frame(maxWidth: field == .number ? 100 : 280)
            Spacer(minLength: 0)
        }
    }
}
