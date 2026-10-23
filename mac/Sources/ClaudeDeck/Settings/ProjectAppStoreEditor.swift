import MonitorKit
import SwiftUI

/// プロジェクトに紐づける App Store Connect のアプリ。一覧から選んで足し、名前（本番・検証用など）を変えられる。名前が空の間は保存しない。
struct ProjectAppStoreEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var draft: [AppStoreAppLink] = []
    /// 最後に設定から欄へ入れた値。利用者が触るまでは書き直さない（開いただけで settings.json を書かないため）。
    @State private var loaded: [AppStoreAppLink] = []
    @State private var hints: AppStoreProjectHints?
    /// 候補はヒントか一覧が替わった時だけ作り直す（描くたびに照合しない）。
    @State private var candidates: [AppStoreCandidate] = []
    @State private var expanded = false
    @FocusState private var focused: Int?

    private var appStore: AppStoreStore { .shared }
    private var key: String { SettingsStore.projectKey(id: project.id, field: "appStore") }

    var body: some View {
        let problems = SettingsValidation.appStoreRowProblems(trimmed(draft))
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(Array(draft.enumerated()), id: \.offset) { index, link in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("名前", text: nameBinding(index), prompt: Text("本番・検証用など"))
                            .settingsField { store.flushPending() }
                            .focused($focused, equals: index)
                            .frame(width: 160)
                        Text(appStore.app(link.appId).map { "\($0.name)（\($0.bundleId)）" } ?? "appId \(link.appId)")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help("appId \(link.appId)")
                        Spacer(minLength: 4)
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("上へ")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == draft.count - 1).help("下へ")
                        Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }
                            .help("このアプリの紐づけを外す（App Store Connect のアプリは変わりません）")
                    }
                    .buttonStyle(.borderless)
                    if problems.indices.contains(index) { SettingsProblems(problems: problems[index]) }
                }
            }
            details
        } label: {
            SettingsItemLabel(title: "App Store",
                              info: "詳細の「App Store」のタブで、版の状態・審査・メタデータを App Store Connect から読んで出します（読むだけ）。鍵は環境変数か \(AppStoreEnvFile.displayPath) から読み、この設定には書きません。追加の「候補」は .claude/appstore.json の appId か、Xcode のバンドル ID が一致するアプリです。",
                              summary: LinkageSummary.count(draft.count), isEmpty: draft.isEmpty,
                              note: note(hasRowProblems: problems.contains { !$0.isEmpty })) {
                addControl
            }
        }
        .onAppear { load(project.appStoreApps) }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す。自分の保存では値が一致するので何もしない）。
        .onChange(of: project.appStoreApps) { _, apps in
            guard trimmed(apps) != trimmed(draft) else {
                loaded = draft
                return
            }
            store.cancelPending(key: key)
            load(apps)
        }
        .onChange(of: draft) { commit() }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
        // 走査はアプリの一覧が取れてから始め、欄を離れたら取りやめる。
        .task(id: ScanKey(path: project.path, ready: appStore.apps.value != nil)) {
            guard appStore.apps.value != nil, hints == nil else { return }
            let path = project.path
            let scan = Task.detached(priority: .userInitiated) { AppStoreCandidates.hints(projectPath: path, isCancelled: { Task.isCancelled }) }
            let found = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            hints = found
        }
        .onChange(of: CandidateKey(hints: hints, apps: appStore.apps.value), initial: true) { _, key in
            candidates = key.hints.flatMap { hints in key.apps.map { AppStoreCandidates.match(apps: $0, hints: hints) } } ?? []
        }
    }

    private struct ScanKey: Equatable {
        let path: String
        let ready: Bool
    }

    private struct CandidateKey: Equatable {
        let hints: AppStoreProjectHints?
        let apps: [AppStoreApp]?
    }

    private func load(_ apps: [AppStoreAppLink]) {
        loaded = apps
        draft = apps
    }

    /// 行に添える一言（一覧の取得に失敗した・閉じた中に保存できない行がある）。
    private func note(hasRowProblems: Bool) -> SettingsNote? {
        if let failure = appStore.apps.failure { return SettingsNote(text: failure.message) }
        if hasRowProblems, !expanded { return SettingsNote(text: "名前が空の行があります（開いて直してください）") }
        return nil
    }

    /// 行の操作: 一覧が取れていれば追加のメニュー、無ければ取得。
    @ViewBuilder
    private var addControl: some View {
        let fetch = appStore.apps
        if fetch.loading { ProgressView().controlSize(.small) }
        if let apps = fetch.value {
            let linked = Set(draft.map(\.appId))
            let rest = apps.filter { app in !candidates.contains { $0.app.id == app.id } }
            Menu {
                if !candidates.isEmpty {
                    Section("候補") {
                        ForEach(candidates) { candidate in
                            Button("\(candidate.app.name)（\(candidate.app.bundleId)）— \(candidate.reasonText)") { add(candidate.app) }
                                .disabled(linked.contains(candidate.app.id))
                        }
                    }
                }
                Section(candidates.isEmpty ? "アプリ" : "ほかのアプリ") {
                    ForEach(rest) { app in
                        Button("\(app.name)（\(app.bundleId)）") { add(app) }
                            .disabled(linked.contains(app.id))
                    }
                }
            } label: {
                Label("追加", systemImage: "plus")
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(apps.isEmpty)
            .help(apps.isEmpty ? "このキーで見られるアプリがありません" : "App Store Connect のアプリを紐づける")
        } else {
            Button("一覧を取得") { appStore.loadApps(force: true) }
                .controlSize(.small)
                .disabled(fetch.loading)
                .help("App Store Connect のアプリの一覧を取得")
        }
    }

    /// 開いた中の下の方: 鍵の読み元・取り直し・.claude/appstore.json の appId が見つからない旨。
    @ViewBuilder
    private var details: some View {
        let fetch = appStore.apps
        if let apps = fetch.value, apps.isEmpty {
            Text("このキーで見られるアプリがありません").font(.caption).foregroundStyle(.secondary)
        }
        if appStore.credentialSource != nil || fetch.value != nil {
            HStack(spacing: 8) {
                if let source = appStore.credentialSource {
                    Text("鍵の読み元: \(source.label)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if fetch.value != nil {
                    Button("一覧を取り直す") { appStore.reloadApps() }
                        .controlSize(.small)
                        .disabled(fetch.loading)
                }
            }
        }
        if let hints, let id = hints.configuredAppId, let apps = fetch.value, !apps.contains(where: { $0.id == id }) {
            Text(".claude/appstore.json の appId（\(id)）はこのキーで見られるアプリにありません").font(.caption).foregroundStyle(.orange)
        }
    }

    private func nameBinding(_ index: Int) -> Binding<String> {
        Binding(get: { draft.indices.contains(index) ? draft[index].name : "" },
                set: { if draft.indices.contains(index) { draft[index].name = $0 } })
    }

    private func trimmed(_ list: [AppStoreAppLink]) -> [AppStoreAppLink] {
        list.map { AppStoreAppLink(appId: $0.appId, name: $0.name.trimmingCharacters(in: .whitespaces)) }
    }

    /// 名前が空の行がある間は保存しない（前の内容のまま）。
    private func commit() {
        guard draft != loaded else {
            store.cancelPending(key: key)
            return
        }
        let next = trimmed(draft)
        guard !next.contains(where: { $0.name.isEmpty }) else {
            store.cancelPending(key: key)
            return
        }
        guard next != project.appStoreApps else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleProject(id: project.id, field: "appStore", \.appStoreApps, next)
    }

    private func add(_ app: AppStoreApp) {
        guard !draft.contains(where: { $0.appId == app.id }) else { return }
        draft.append(AppStoreAppLink(appId: app.id, name: app.name.isEmpty ? app.bundleId : app.name))
        expanded = true
        commitNow()
    }

    private func remove(_ index: Int) {
        guard draft.indices.contains(index) else { return }
        draft.remove(at: index)
        commitNow()
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard draft.indices.contains(index), draft.indices.contains(target) else { return }
        draft.swapAt(index, target)
        commitNow()
    }

    /// 追加・削除・並べ替えはすぐ書く（`onChange` を待たずに）。
    private func commitNow() {
        commit()
        store.flushPending()
    }
}
