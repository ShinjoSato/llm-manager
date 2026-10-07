import AppKit
import MonitorKit
import SwiftUI

/// 詳細の「リンク」の 1 行。クリックで開き、ホバーで「編集」「上へ」「下へ」「削除」を出す。
struct ProjectLinkRow: View {
    let projectID: UUID
    let index: Int
    let count: Int
    let link: ProjectLink
    /// 設定画面と同じ検証の結果（あれば開けないので理由を出す）。
    let problems: [String]
    let open: () -> Void
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        let openable = problems.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Image(systemName: link.resolvedKind.symbol)
                            .font(.system(size: 11))
                            .frame(width: 14)
                            .foregroundStyle(openable ? ChatTheme.link : ChatTheme.tertiary)
                            .help(link.resolvedKind.label)
                        Text(link.name.isEmpty ? "（名前なし）" : link.name)
                            .font(ChatTheme.body)
                            .foregroundStyle(openable ? ChatTheme.text : ChatTheme.tertiary)
                            .lineLimit(1)
                        Text(link.url)
                            .font(ChatTheme.caption)
                            .foregroundStyle(ChatTheme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!openable)
                .help(openable ? ProjectLinks.help(for: link) : problems.joined(separator: "・"))
                HStack(spacing: 2) {
                    ProjectLinkRowButton(symbol: "pencil", name: "編集") { editing = true }
                        .popover(isPresented: $editing, arrowEdge: .bottom) {
                            ProjectLinkForm(projectID: projectID, index: index, initial: link) { editing = false }
                        }
                    ProjectLinkRowButton(symbol: "chevron.up", name: "上へ") { ProjectLinkActions.move(projectID: projectID, index: index, by: -1, expecting: link) }
                        .disabled(index == 0)
                    ProjectLinkRowButton(symbol: "chevron.down", name: "下へ") { ProjectLinkActions.move(projectID: projectID, index: index, by: 1, expecting: link) }
                        .disabled(index == count - 1)
                    ProjectLinkRowButton(symbol: "trash", name: "削除") { ProjectLinkActions.remove(projectID: projectID, index: index, expecting: link) }
                }
                // 場所を変えずに、ホバーと編集中だけ見せる。
                .opacity(hovering || editing ? 1 : 0)
            }
            if !openable {
                Text(problems.joined(separator: "・"))
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.error)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// 節の下の「+ 追加」。クリップボードに http / https のアドレスがあれば URL 欄の初期値にする。
struct ProjectLinkAddButton: View {
    let projectID: UUID
    @State private var adding = false
    @State private var initial = ProjectLink(name: "", url: "")

    var body: some View {
        Button {
            initial = ProjectLink(name: "", url: ProjectLinkActions.clipboardURLText() ?? "")
            adding = true
        } label: {
            Label("追加", systemImage: "plus")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.link)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("リンクを追加（クリップボードのアドレスを初期値にします）")
        .popover(isPresented: $adding, arrowEdge: .bottom) {
            ProjectLinkForm(projectID: projectID, index: nil, initial: initial) { adding = false }
        }
    }
}

/// 行の右の小さなアイコンボタン。
private struct ProjectLinkRowButton: View {
    let symbol: String
    let name: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isEnabled ? ChatTheme.text : ChatTheme.tertiary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? ChatTheme.selectedRow : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .onHover { hovering = $0 }
    }
}

/// 追加・編集のポップオーバー。名前・URL・種類を検証（設定画面と同じ）し、問題が無い時だけ保存できる。
/// 保存は `links` 全体を 1 回で置き換えて設定ファイルに即時に書く（設定画面を開いていても揃う）。
struct ProjectLinkForm: View {
    let projectID: UUID
    /// 編集なら元の位置（追加なら nil）。
    let index: Int?
    let onClose: () -> Void

    /// 開いた時の行。親の描き直しで行がずれても、保存の照合はこれと行う。
    @State private var initial: ProjectLink
    @State private var name: String
    @State private var urlText: String
    @State private var kind: ProjectLinkKind
    @State private var nameTouched: Bool
    @State private var kindTouched = false
    @State private var kindSuggested = false
    @State private var titleTask: Task<Void, Never>?
    @State private var fetchGeneration = 0
    @State private var fetchingTitle = false
    @State private var failure: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, url }

    init(projectID: UUID, index: Int?, initial: ProjectLink, onClose: @escaping () -> Void) {
        self.projectID = projectID
        self.index = index
        self.onClose = onClose
        _initial = State(initialValue: initial)
        _name = State(initialValue: initial.name)
        _urlText = State(initialValue: initial.url)
        _kind = State(initialValue: initial.resolvedKind)
        // 編集では入っている名前を提案で置き換えない。
        _nameTouched = State(initialValue: index != nil)
    }

    private var isEditing: Bool { index != nil }

    private var store: SettingsStore { SettingsStore.shared }

    private var candidate: ProjectLink {
        ProjectLink(name: name.trimmingCharacters(in: .whitespaces),
                    url: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: ProjectLinks.kindToSave(selected: kind, touched: kindTouched, suggested: kindSuggested, original: initial.kind))
    }

    /// 自動で取りに行くのはクエリの無いアドレスだけ（一度きりのログイン用リンク等を使い切らない）。
    private var autoFetchable: Bool {
        guard let url = ProjectLinks.url(from: urlText) else { return false }
        return url.query == nil && url.fragment == nil
    }

    /// 今の設定のリンク（外で変わっていれば最新を見る）。
    private var currentLinks: [ProjectLink] {
        store.projects.first(where: { $0.id == projectID })?.links ?? []
    }

    /// 他の行と合わせた検証（同じ名前の判定のため）。
    private var problems: [String] {
        var links = currentLinks
        let position: Int
        if let index, links.indices.contains(index) {
            links[index] = candidate
            position = index
        } else {
            links.append(candidate)
            position = links.count - 1
        }
        let rows = SettingsValidation.projectLinkRowProblems(links)
        return rows.indices.contains(position) ? rows[position] : []
    }

    var body: some View {
        let problems = problems
        VStack(alignment: .leading, spacing: 12) {
            Text(index == nil ? "リンクを追加" : "リンクを編集")
                .font(ChatTheme.headline)
                .foregroundStyle(ChatTheme.heading)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("名前")
                    HStack(spacing: 6) {
                        TextField("名前", text: Binding(get: { name }, set: { if $0 != name { name = $0; nameTouched = true } }), prompt: Text("例: Stripe"))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: .name)
                            .onSubmit(save)
                        Button { fetchTitle(delay: false, force: true) } label: {
                            if fetchingTitle { ProgressView().controlSize(.small) } else { Image(systemName: "text.magnifyingglass") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(fetchingTitle || ProjectLinks.url(from: urlText) == nil)
                        .help("ページの題名を名前に入れる（このアドレスを取りに行きます）")
                    }
                }
                GridRow {
                    label("URL")
                    TextField("URL", text: $urlText, prompt: Text("https://…"))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .url)
                        .onSubmit(save)
                }
                GridRow {
                    label("種類")
                    Picker("種類", selection: Binding(get: { kind }, set: { if $0 != kind { kind = $0; kindTouched = true } })) {
                        ForEach(ProjectLinkKind.allCases, id: \.self) { kind in
                            Label(kind.label, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .leading)
                }
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { Text($0).font(ChatTheme.caption).foregroundStyle(ChatTheme.error) }
                }
            }
            if let failure {
                Text(failure).font(ChatTheme.caption).foregroundStyle(ChatTheme.error)
            }
            HStack {
                Spacer()
                Button("キャンセル", action: onClose).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(!problems.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            if index == nil { suggest(delay: false) }
            focused = index == nil && initial.url.isEmpty ? .url : .name
        }
        .onChange(of: urlText) { suggest(delay: true) }
        // 閉じたら取りに行っていた題名は捨てる。
        .onDisappear { titleTask?.cancel() }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary).gridColumnAlignment(.trailing)
    }

    /// URL から種類と名前を提案し、クエリの無いアドレスならページの題名も取りに行く。利用者が触った欄は置き換えない。
    private func suggest(delay: Bool) {
        titleTask?.cancel()
        titleTask = nil
        fetchingTitle = false
        guard let url = ProjectLinks.url(from: urlText) else { return }
        // 編集では選んである種類を提案で上書きしない。
        if !isEditing, !kindTouched {
            kind = ProjectLinkKind.suggest(for: url)
            kindSuggested = true
        }
        guard !nameTouched else { return }
        if let host = ProjectLinks.suggestedName(for: url) { name = host }
        if autoFetchable { fetchTitle(delay: delay) }
    }

    /// 題名を取りに行き、戻るまでに利用者が名前を触っていなければ入れる。ボタンからは触っていても入れる。
    private func fetchTitle(delay: Bool, force: Bool = false) {
        titleTask?.cancel()
        let text = urlText
        fetchGeneration += 1
        let generation = fetchGeneration
        titleTask = Task { @MainActor in
            if delay { try? await Task.sleep(for: .milliseconds(800)) }
            guard !Task.isCancelled else { return }
            fetchingTitle = true
            // 取り消された古い取得が、新しい取得の表示を消さないように自分の番だけ戻す。
            defer { if fetchGeneration == generation { fetchingTitle = false } }
            guard let title = await LinkTitleFetcher.title(for: text), !Task.isCancelled else { return }
            guard urlText == text, force || !nameTouched else { return }
            name = title
        }
    }

    private func save() {
        guard problems.isEmpty else { return }
        let link = candidate
        let index = index
        let initial = initial
        if let index {
            let links = currentLinks
            guard links.indices.contains(index), links[index] == initial else {
                failure = "このリンクは外で変わりました。閉じて開き直してください"
                return
            }
        }
        // 溜めていた設定画面の変更が先に当たって行がずれた時は、黙って閉じずに知らせる。
        var applied = false
        let saved = store.updateProject(id: projectID) { project in
            if let index {
                guard project.links.indices.contains(index), project.links[index] == initial else { return }
                project.links[index] = link
            } else {
                project.links.append(link)
            }
            applied = true
        }
        guard saved, applied else {
            failure = saved ? "このリンクは外で変わりました。閉じて開き直してください" : (store.problem ?? "保存できませんでした")
            return
        }
        onClose()
    }
}

/// 行のボタンからの並べ替え・削除と、クリップボードの読み取り。設定の今の内容を見て、行が外で変わっていれば何もしない。
enum ProjectLinkActions {
    @MainActor
    static func move(projectID: UUID, index: Int, by delta: Int, expecting link: ProjectLink) {
        _ = SettingsStore.shared.updateProject(id: projectID) { project in
            let target = index + delta
            guard project.links.indices.contains(index), project.links.indices.contains(target), project.links[index] == link else { return }
            project.links.swapAt(index, target)
        }
    }

    @MainActor
    static func remove(projectID: UUID, index: Int, expecting link: ProjectLink) {
        _ = SettingsStore.shared.updateProject(id: projectID) { project in
            guard project.links.indices.contains(index), project.links[index] == link else { return }
            project.links.remove(at: index)
        }
    }

    /// クリップボードの文字列が http / https のアドレスならそれ（前後の空白は落とす）。
    static func clipboardURLText(_ pasteboard: NSPasteboard = .general) -> String? {
        guard let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectLinks.url(from: trimmed) == nil ? nil : trimmed
    }
}
