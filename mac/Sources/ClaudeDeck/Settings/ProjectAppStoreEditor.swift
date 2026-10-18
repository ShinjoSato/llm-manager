import MonitorKit
import SwiftUI

/// プロジェクトに紐づける App Store Connect のアプリ。一覧から選んで足し、名前（本番・検証用など）を変えられる。名前が空の間は保存しない。
struct ProjectAppStoreEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var draft: [AppStoreAppLink] = []
    @State private var hints: AppStoreProjectHints?
    @FocusState private var focused: Int?

    private var appStore: AppStoreStore { .shared }
    private var key: String { SettingsStore.projectKey(id: project.id, field: "appStore") }

    var body: some View {
        Section {
            if draft.isEmpty {
                Text("紐づけたアプリはありません").foregroundStyle(.secondary)
            }
            let problems = SettingsValidation.appStoreRowProblems(trimmed(draft))
            ForEach(Array(draft.enumerated()), id: \.offset) { index, link in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("名前", text: nameBinding(index), prompt: Text("本番・検証用など"))
                            .settingsField { store.flushPending() }
                            .focused($focused, equals: index)
                            .frame(width: 180)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appStore.app(link.appId).map { "\($0.name)（\($0.bundleId)）" } ?? "appId \(link.appId)")
                                .lineLimit(1).truncationMode(.middle)
                            Text(link.appId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
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
            addRow
        } header: {
            Text("App Store")
        } footer: {
            Text("ディレクトリの詳細の「App Store」のタブで、版の状態・審査・メタデータの文面を App Store Connect から読んで出します（読むだけ）。鍵は appstore-plugin と同じ \(AppStoreEnvFile.displayPath) から読み、この設定には書きません。候補は .claude/appstore.json の appId と、Xcode のプロジェクトのバンドル ID が一致するアプリです。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { draft = project.appStoreApps }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す。自分の保存では値が一致するので何もしない）。
        .onChange(of: project.appStoreApps) { _, apps in
            guard apps != trimmed(draft) else { return }
            store.cancelPending(key: key)
            draft = apps
        }
        .onChange(of: draft) { commit() }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
        .task(id: project.path) {
            let path = project.path
            hints = await Task.detached(priority: .userInitiated) { AppStoreCandidates.hints(projectPath: path) }.value
        }
    }

    @ViewBuilder
    private var addRow: some View {
        let fetch = appStore.apps
        HStack(spacing: 8) {
            if let apps = fetch.value {
                let linked = Set(draft.map(\.appId))
                let candidates = hints.map { AppStoreCandidates.match(apps: apps, hints: $0) } ?? []
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
                    Label("アプリを追加", systemImage: "plus")
                }
                .fixedSize()
                .disabled(apps.isEmpty)
                if apps.isEmpty { Text("このキーで見られるアプリがありません").font(.caption).foregroundStyle(.secondary) }
            } else {
                Button { appStore.loadApps(force: true) } label: { Label("App Store Connect のアプリの一覧を取得", systemImage: "arrow.down.circle") }
                    .disabled(fetch.loading)
            }
            if fetch.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            if fetch.value != nil {
                Button("一覧を取り直す") { appStore.reload(appIds: []) }
                    .controlSize(.small)
                    .disabled(fetch.loading)
            }
        }
        if let failure = fetch.failure {
            Text(failure.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
