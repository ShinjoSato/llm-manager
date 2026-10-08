import MonitorKit
import SwiftUI

/// GitHub の紐づけとボード。欄が正しい間だけ保存する（settings.json に不正な値を残さない）。
struct GitHubSettingsTab: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section {
                if store.projects.isEmpty {
                    Text("プロジェクトがありません。「プロジェクト」タブで追加してください。").foregroundStyle(.secondary)
                }
                ForEach(store.projects) { project in
                    GitHubLinkEditor(store: store, project: project)
                }
            } header: {
                Text("プロジェクト")
            } footer: {
                Text("owner はユーザーか Organization の名前、リポジトリは名前だけ（owner/ は付けない）。Project 番号はボードの URL の末尾の数字です。全部空にすると紐づけを外します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(store.settings.boards) { board in
                    BoardEditor(store: store, board: board)
                }
                NewBoardRow(store: store)
            } header: {
                Text("リポジトリに紐づかないボード")
            } footer: {
                Text("複数のリポジトリをまたぐボードなど。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.isEditable)
    }
}

private struct GitHubLinkEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var owner = ""
    @State private var repo = ""
    @State private var number = ""
    @State private var problems: [String] = []
    @FocusState private var focused: Int?

    private var key: String { SettingsStore.projectKey(id: project.id, field: "github") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.body.weight(.semibold))
            HStack(spacing: 8) {
                field("owner", text: $owner).focused($focused, equals: 0)
                Text("/").foregroundStyle(.secondary)
                field("リポジトリ", text: $repo).focused($focused, equals: 1)
                field("Project 番号", text: $number).focused($focused, equals: 2).frame(width: 100)
            }
            SettingsProblems(problems: problems)
        }
        .padding(.vertical, 2)
        .onAppear { load(project.github) }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す）。
        .onChange(of: project.github) { _, link in
            guard link != draft else { return }
            store.cancelPending(key: key)
            load(link)
        }
        .onChange(of: owner) { commit() }
        .onChange(of: repo) { commit() }
        .onChange(of: number) { commit() }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title)).settingsField { store.flushPending() }
    }

    /// 欄の今の中身（全部空なら紐づけ無し）。
    private var draft: GitHubLink? {
        let o = owner.trimmingCharacters(in: .whitespaces)
        let r = repo.trimmingCharacters(in: .whitespaces)
        let n = SettingsValidation.parseNumber(number)
        if o.isEmpty && r.isEmpty && n == nil { return nil }
        return GitHubLink(owner: o, repo: r.isEmpty ? nil : r, projectNumber: n)
    }

    private func load(_ link: GitHubLink?) {
        owner = link?.owner ?? ""
        repo = link?.repo ?? ""
        number = link?.projectNumber.map(String.init) ?? ""
        problems = []
    }

    private func commit() {
        let link = draft
        problems = link.map(SettingsValidation.linkProblems) ?? []
        guard problems.isEmpty else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleProject(id: project.id, field: "github", \.github, link)
    }
}

private struct BoardEditor: View {
    let store: SettingsStore
    let board: GitHubBoard
    @State private var name = ""
    @State private var owner = ""
    @State private var number = ""
    @State private var problems: [String] = []
    @FocusState private var focused: Int?

    private var key: String { SettingsStore.boardKey(id: board.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BoardFields(name: $name, owner: $owner, number: $number, focused: $focused) { store.flushPending() }
                Button(role: .destructive) { store.removeBoard(id: board.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("このボードを削除")
            }
            SettingsProblems(problems: problems)
        }
        .onAppear { load(board) }
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

    private var draft: GitHubBoard { GitHubBoard.draft(name: name, owner: owner, number: number) }

    private func load(_ value: GitHubBoard) {
        name = value.name
        owner = value.owner
        number = String(value.number)
        problems = []
    }

    private func commit() {
        let value = draft
        problems = value.problems(among: store.settings.boards, excluding: board.id)
        guard problems.isEmpty else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleBoard(id: board.id, value)
    }
}

private struct NewBoardRow: View {
    let store: SettingsStore
    @State private var name = ""
    @State private var owner = ""
    @State private var number = ""
    @FocusState private var focused: Int?

    private var draft: GitHubBoard { GitHubBoard.draft(name: name, owner: owner, number: number) }

    private var problems: [String] {
        if name.isEmpty && owner.isEmpty && number.isEmpty { return [] }
        return draft.problems(among: store.settings.boards, excluding: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BoardFields(name: $name, owner: $owner, number: $number, focused: $focused) {}
                Button("追加") {
                    store.addBoard(draft)
                    name = ""
                    owner = ""
                    number = ""
                }
                .disabled(name.isEmpty || !problems.isEmpty)
            }
            SettingsProblems(problems: problems)
        }
    }
}

private struct BoardFields: View {
    @Binding var name: String
    @Binding var owner: String
    @Binding var number: String
    var focused: FocusState<Int?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        TextField("名前", text: $name, prompt: Text("名前")).settingsField(onSubmit: onSubmit)
            .focused(focused, equals: 0)
        TextField("owner", text: $owner, prompt: Text("owner")).settingsField(onSubmit: onSubmit)
            .focused(focused, equals: 1)
        TextField("Project 番号", text: $number, prompt: Text("Project 番号")).settingsField(onSubmit: onSubmit)
            .focused(focused, equals: 2)
            .frame(width: 100)
    }
}

private extension GitHubBoard {
    /// 欄の中身から組む（前後の空白は落とし、番号が読めなければ 0）。
    static func draft(name: String, owner: String, number: String) -> GitHubBoard {
        GitHubBoard(name: name.trimmingCharacters(in: .whitespaces), owner: owner.trimmingCharacters(in: .whitespaces),
                    number: SettingsValidation.parseNumber(number) ?? 0)
    }

    /// 保存できない理由。`id` の行（編集中の自分）を除いて同じボードがあればそれも出す。
    func problems(among boards: [GitHubBoard], excluding id: UUID?) -> [String] {
        let problems = SettingsValidation.boardProblems(self)
        if problems.isEmpty, boards.contains(where: { $0.id != id && $0.sameBoard(as: self) }) {
            return ["同じボードが既にあります"]
        }
        return problems
    }
}
