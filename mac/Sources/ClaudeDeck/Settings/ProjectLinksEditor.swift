import MonitorKit
import SwiftUI

/// プロジェクトのリンク（LP 等）の追加・編集・削除・並べ替え。
/// 全行が正しい間だけ保存する（途中の行があればファイルは前の内容のまま）。文字欄は少し間を置いてまとめて書く。
/// 名前と URL が両方空の行は画面に残すだけで保存の対象にしない（「追加」した直後の行が他の行の保存を止めないため）。
struct ProjectLinksEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var rows: [Row] = []
    @State private var problems: [[String]] = []
    /// 最後に設定から欄へ入れた値。利用者が触るまでは空白を落としただけの差を書き直さないために持つ。
    @State private var loaded: [ProjectLink] = []
    @FocusState private var focused: Field?

    /// 画面で行を見分けるためだけの印（ファイルには書かない）。
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var url: String
    }

    private enum Field: Hashable {
        case name(UUID), url(UUID)
    }

    private var key: String { SettingsStore.projectKey(id: project.id, field: "links") }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("リンクはありません").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        field("名前", text: binding(index, \.name)).focused($focused, equals: .name(row.id)).frame(width: 140)
                        field("https://…", text: binding(index, \.url)).focused($focused, equals: .url(row.id))
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("上へ")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == rows.count - 1).help("下へ")
                        Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }
                            .help("このリンクを削除")
                    }
                    .buttonStyle(.borderless)
                    if problems.indices.contains(index) {
                        ForEach(problems[index], id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Button {
                let row = Row(name: "", url: "")
                rows.append(row)
                focused = .name(row.id)
            } label: { Label("リンクを追加", systemImage: "plus") }
        } header: {
            Text("リンク")
        } footer: {
            Text("LP やデザインなど、このプロジェクトの会話の見出しの「リンク」から既定のブラウザで開くアドレス（http / https）。名前はプロジェクトの中で重ねられません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load(project.links) }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す。自分の保存では値が一致するので何もしない）。
        .onChange(of: project.links) { _, links in
            guard links != draft else { return }
            store.cancelPending(key: key)
            load(links)
        }
        .onChange(of: rows) { commit() }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { store.flushPending() }
    }

    private func binding(_ index: Int, _ keyPath: WritableKeyPath<Row, String>) -> Binding<String> {
        Binding(get: { rows.indices.contains(index) ? rows[index][keyPath: keyPath] : "" },
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

    /// 欄の今の中身を行ごとに（前後の空白は落とす）。名前と URL が両方空の行は nil。
    private var trimmedRows: [ProjectLink?] {
        rows.map { row in
            let link = ProjectLink(name: row.name.trimmingCharacters(in: .whitespaces),
                                   url: row.url.trimmingCharacters(in: .whitespacesAndNewlines))
            return link.name.isEmpty && link.url.isEmpty ? nil : link
        }
    }

    /// 保存の対象になる行だけ。
    private var trimmed: [ProjectLink] { trimmedRows.compactMap { $0 } }

    /// 欄の中身をそのまま（利用者が触っていないかを見るため）。
    private var raw: [ProjectLink] { rows.map { ProjectLink(name: $0.name, url: $0.url) } }

    /// 行ごとの問題（空の行は問題なし）。並びは `rows` と同じ。
    private var rowProblems: [[String]] {
        var problems = SettingsValidation.projectLinkRowProblems(trimmed).makeIterator()
        return trimmedRows.map { $0 == nil ? [] : (problems.next() ?? []) }
    }

    /// 全行が正しい時だけ保存する形。どこかが途中なら nil。
    private var draft: [ProjectLink]? {
        rowProblems.allSatisfy(\.isEmpty) ? trimmed : nil
    }

    private func load(_ links: [ProjectLink]) {
        rows = links.map { Row(name: $0.name, url: $0.url) }
        loaded = links
        problems = []
    }

    private func commit() {
        problems = rowProblems
        // 設定から入れたままなら予約しない（開いただけで書き直さない）。
        guard raw != loaded else { return }
        let links = trimmed
        // 欄の中身が設定と同じなら書くものは無い（前の入力の予約も要らない）。
        guard links != project.links else {
            store.cancelPending(key: key)
            return
        }
        guard problems.allSatisfy(\.isEmpty) else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleProject(id: project.id, field: "links", \.links, links)
    }
}
