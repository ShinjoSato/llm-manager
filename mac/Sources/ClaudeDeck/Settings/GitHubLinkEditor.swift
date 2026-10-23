import AppKit
import MonitorKit
import SwiftUI

/// プロジェクトの GitHub の紐づけの欄。欄が正しい間だけ保存する。
/// そのフォルダの git の remote にある github.com のリポジトリを候補に出し、押すと owner とリポジトリに入れる。
struct GitHubLinkEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    /// 保存できない理由が変わった時に知らせる。
    var onProblems: (([String]) -> Void)?
    @State private var owner = ""
    @State private var repo = ""
    @State private var number = ""
    @State private var problems: [String] = []
    @State private var remotes: [GitHubRemoteCandidate] = []
    @FocusState private var focused: Int?

    private var key: String { SettingsStore.projectKey(id: project.id, field: "github") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .onChange(of: problems) { _, value in onProblems?(value) }
        .task(id: project.path) {
            let path = project.path
            let found = await Task.detached(priority: .utility) { GitRemotes.githubCandidates(projectPath: path) }.value
            guard !Task.isCancelled else { return }
            remotes = found
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

    /// 前後の空白と空のリポジトリを除いて同じ紐づけか。
    private static func sameMeaning(_ a: GitHubLink?, _ b: GitHubLink?) -> Bool {
        func normalized(_ link: GitHubLink?) -> GitHubLink? {
            guard let link else { return nil }
            let repo = link.repo?.trimmingCharacters(in: .whitespaces)
            return GitHubLink(owner: link.owner.trimmingCharacters(in: .whitespaces),
                              repo: repo?.isEmpty == true ? nil : repo, projectNumber: link.projectNumber)
        }
        return normalized(a) == normalized(b)
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
        // 開いた・読み込んだだけ（今の値と同じ意味）では書かない。
        guard problems.isEmpty, !Self.sameMeaning(link, project.github) else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleProject(id: project.id, field: "github", \.github, link)
    }
}

/// プロジェクトの画面の紐づけの「GitHub」の行。開くと欄を出す。
struct ProjectGitHubRow: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var expanded = false
    /// 開いた欄の保存できない理由。ある間は閉じない（閉じると欄ごと途中の入力が消えるため）。
    @State private var draftProblems: [String] = []

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: setExpanded)) {
            GitHubLinkEditor(store: store, project: project) { draftProblems = $0 }
        } label: {
            SettingsItemLabel(title: "GitHub",
                              info: "見出しの「GitHub」ボタンが開く先。owner はユーザーか Organization、リポジトリは名前だけ、Project 番号はボードの URL の末尾の数字。全部空にすると外れます。リポジトリに紐づかないボードは左の一覧の「横断ボード」で設定します。",
                              summary: LinkageSummary.github(project.github), isEmpty: project.github == nil,
                              notes: expanded ? [] : savedProblems) {
                Button(expanded ? "閉じる" : "編集") { setExpanded(!expanded) }
                    .controlSize(.small)
                    .disabled(expanded && !draftProblems.isEmpty)
                    .help(expanded && !draftProblems.isEmpty ? "保存できない入力がある間は閉じられません" : "")
            }
        }
        .onDisappear { store.flushPending(force: true) }
    }

    /// 設定に書かれている紐づけの問題（手で書いた不正な値など）。
    private var savedProblems: [SettingsNote] {
        (project.github.map(SettingsValidation.linkProblems) ?? []).map { SettingsNote(text: $0, isError: false) }
    }

    private func setExpanded(_ open: Bool) {
        guard open || draftProblems.isEmpty else {
            NSSound.beep()
            return
        }
        if !open { store.flushPending() }
        expanded = open
    }
}
