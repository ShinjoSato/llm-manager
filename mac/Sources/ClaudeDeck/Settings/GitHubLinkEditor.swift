import MonitorKit
import SwiftUI

/// プロジェクトの GitHub の紐づけの欄（GitHub タブとプロジェクトの画面で共通）。欄が正しい間だけ保存する。
/// そのフォルダの git の remote にある github.com のリポジトリを候補に出し、押すと owner とリポジトリに入れる。
struct GitHubLinkEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    var showsName = true
    @State private var owner = ""
    @State private var repo = ""
    @State private var number = ""
    @State private var problems: [String] = []
    @State private var remotes: [GitHubRemoteCandidate] = []
    @FocusState private var focused: Int?

    private var key: String { SettingsStore.projectKey(id: project.id, field: "github") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsName { Text(project.name).font(.body.weight(.semibold)) }
            HStack(spacing: 8) {
                field("owner", text: $owner).focused($focused, equals: 0)
                Text("/").foregroundStyle(.secondary)
                field("リポジトリ", text: $repo).focused($focused, equals: 1)
                field("Project 番号", text: $number).focused($focused, equals: 2).frame(width: 100)
            }
            SettingsProblems(problems: problems)
            suggestions
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
        .task(id: project.path) {
            let path = project.path
            remotes = await Task.detached(priority: .utility) { GitRemotes.githubCandidates(projectPath: path) }.value
        }
    }

    /// 今の欄と違う候補だけ出す。
    @ViewBuilder
    private var suggestions: some View {
        let shown = remotes.filter { candidate in
            candidate.owner.caseInsensitiveCompare(owner.trimmingCharacters(in: .whitespaces)) != .orderedSame
                || candidate.repo.caseInsensitiveCompare(repo.trimmingCharacters(in: .whitespaces)) != .orderedSame
        }
        if !shown.isEmpty {
            HStack(spacing: 6) {
                Text("git の remote:").font(.caption).foregroundStyle(.secondary)
                ForEach(shown, id: \.remote) { candidate in
                    Button("\(candidate.owner)/\(candidate.repo)") { use(candidate) }
                        .controlSize(.small)
                        .help("remote「\(candidate.remote)」の owner とリポジトリを入れる（Project 番号はそのまま）")
                }
            }
        }
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

    private func use(_ candidate: GitHubRemoteCandidate) {
        owner = candidate.owner
        repo = candidate.repo
        commit()
        store.flushPending()
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

/// プロジェクトの画面の「GitHub」の節。
struct ProjectGitHubSection: View {
    let store: SettingsStore
    let project: ManagedProject

    var body: some View {
        Section {
            GitHubLinkEditor(store: store, project: project, showsName: false)
        } header: {
            LinkageHeader(title: "GitHub", shows: "ボタンの「GitHub」")
        } footer: {
            Text("owner はユーザーか Organization の名前、リポジトリは名前だけ（owner/ は付けない）。Project 番号はボードの URL の末尾の数字です。全部空にすると紐づけを外します。「GitHub」タブと同じ値です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
