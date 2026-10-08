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
        var kind: ProjectLinkKind?
        var pinned: Bool
        var note: String
        var remind: Bool
        var day: Int

        init(_ link: ProjectLink) {
            name = link.name
            url = link.url
            kind = link.kind
            pinned = link.isPinned
            note = link.resolvedNote
            remind = link.validReminderDay != nil
            day = link.validReminderDay ?? 1
        }

        /// 欄の中身をそのまま（利用者が触っていないかを見るため）。
        var raw: ProjectLink {
            ProjectLink(name: name, url: url, kind: kind, pinned: pinned ? true : nil, note: note.isEmpty ? nil : note, reminderDay: remind ? day : nil)
        }

        /// 保存する形（前後の空白は落とす）。
        var trimmed: ProjectLink {
            ProjectLink(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        kind: kind, pinned: pinned ? true : nil, note: ProjectLinks.noteToSave(note), reminderDay: remind ? day : nil)
        }
    }

    private enum Field: Hashable {
        case name(UUID), url(UUID), note(UUID), day(UUID)
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
                        field("名前", text: binding(index, \.name, fallback: "")).focused($focused, equals: .name(row.id)).frame(width: 140)
                        field("https://…", text: binding(index, \.url, fallback: "")).focused($focused, equals: .url(row.id))
                        Picker("種類", selection: kindBinding(index)) {
                            ForEach(ProjectLinkKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .help("種類（アイコンで見分け、メニューを区切ります）")
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("上へ")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == rows.count - 1).help("下へ")
                        Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }
                            .help("このリンクを削除")
                    }
                    .buttonStyle(.borderless)
                    HStack(spacing: 8) {
                        Toggle("ピン", isOn: binding(index, \.pinned, fallback: false)).toggleStyle(.checkbox)
                            .help("会話と詳細の見出しに単独のボタンで出す（設定の順に \(ProjectLinks.pinLimit) つまで）")
                        field("メモ（1 行）", text: binding(index, \.note, fallback: "")).focused($focused, equals: .note(row.id))
                        Toggle("毎月", isOn: binding(index, \.remind, fallback: false)).toggleStyle(.checkbox)
                        Stepper(value: binding(index, \.day, fallback: 1), in: 1...31) {
                            TextField("日", value: binding(index, \.day, fallback: 1), format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                                .focused($focused, equals: .day(row.id))
                                .onSubmit { store.flushPending() }
                        }
                        .disabled(!row.remind)
                        Text("日に確認").font(.caption).foregroundStyle(.secondary)
                    }
                    if problems.indices.contains(index) {
                        SettingsProblems(problems: problems[index])
                    }
                }
            }
            Button {
                let row = Row(ProjectLink(name: "", url: ""))
                rows.append(row)
                focused = .name(row.id)
            } label: { Label("リンクを追加", systemImage: "plus") }
        } header: {
            Text("リンク")
        } footer: {
            Text("LP やデザインなど、このプロジェクトの会話の見出しの「リンク」から既定のブラウザで開くアドレス（http / https）。名前はプロジェクトの中で重ねられません。「毎月 N 日に確認」は、その日を過ぎてアプリから開いていなければ印を出します（最終確認日は link-visits.json に持ち、この設定には書きません）。")
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
        TextField(title, text: text, prompt: Text(title)).settingsField { store.flushPending() }
    }

    /// 行の欄。消した直後の描き直しで添字が外れていれば `fallback` を見せ、書き込みは捨てる。
    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<Row, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { rows.indices.contains(index) ? rows[index][keyPath: keyPath] : fallback },
                set: { if rows.indices.contains(index) { rows[index][keyPath: keyPath] = $0 } })
    }

    /// 種類の欄。無い（従来の形）行は「その他」として見せ、選んだ時だけ値を持つ。
    private func kindBinding(_ index: Int) -> Binding<ProjectLinkKind> {
        Binding(get: { rows.indices.contains(index) ? rows[index].kind ?? .other : .other },
                set: { if rows.indices.contains(index) { rows[index].kind = $0 } })
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
            let link = row.trimmed
            return link.name.isEmpty && link.url.isEmpty ? nil : link
        }
    }

    /// 保存の対象になる行だけ。
    private var trimmed: [ProjectLink] { trimmedRows.compactMap { $0 } }

    /// 欄の中身をそのまま（利用者が触っていないかを見るため）。
    private var raw: [ProjectLink] { rows.map(\.raw) }

    /// 行ごとの問題（空の行は問題なし）。並びは `rows` と同じ。
    private var rowProblems: [[String]] {
        var problems = SettingsValidation.projectLinkRowProblems(trimmed).makeIterator()
        return trimmedRows.map { link in
            guard let link else { return [] }
            return (problems.next() ?? []) + [SettingsValidation.reminderDayProblem(link.reminderDay)].compactMap { $0 }
        }
    }

    /// 全行が正しい時だけ保存する形。どこかが途中なら nil。
    private var draft: [ProjectLink]? {
        rowProblems.allSatisfy(\.isEmpty) ? trimmed : nil
    }

    private func load(_ links: [ProjectLink]) {
        rows = links.map(Row.init)
        // 比べるのは欄に入れた形（ファイルの `pinned: false` 等を触っていないのに書き直さない）。
        loaded = rows.map(\.raw)
        problems = []
    }

    /// 同じ名前の行の URL を変えた時は最終確認日を新しい URL へ引き継ぐ（今の設定の行と比べる）。
    private func carryVisits(_ links: [ProjectLink]) {
        for link in links {
            guard let current = project.links.first(where: { $0.name.trimmingCharacters(in: .whitespaces) == link.name }),
                  current.url != link.url else { continue }
            LinkVisitStore.shared.carry(projectID: project.id, from: current.url, to: link.url)
        }
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
        carryVisits(links)
        store.scheduleProject(id: project.id, field: "links", \.links, links)
    }
}
