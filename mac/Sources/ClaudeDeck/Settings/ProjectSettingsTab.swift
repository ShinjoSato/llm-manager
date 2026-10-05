import AppKit
import MonitorKit
import SwiftUI

/// プロジェクト: 一覧（並べ替え・追加・削除）と、選んだものの名前・状態・メモ。
struct ProjectSettingsTab: View {
    let store: SettingsStore
    @State private var selection: UUID?
    @State private var deleting: ManagedProject?

    private var selected: ManagedProject? {
        store.projects.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.projects) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.body.weight(.medium))
                            Text(project.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(project.id)
                        .contextMenu {
                            Button("一覧から削除…", role: .destructive) { deleting = project }
                        }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .overlay {
                    if store.projects.isEmpty {
                        Text("プロジェクトがありません").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button { addFolders() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                        .help("フォルダを選んで追加")
                    Button { deleting = selected } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .help("選んだプロジェクトを一覧から削除")
                        .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 220)
            .disabled(!store.isEditable)
            Divider()
            if let project = selected {
                ProjectDetailForm(store: store, project: project)
                    .id(project.id)
            } else {
                Text(store.projects.isEmpty ? "「+」でフォルダを追加してください" : "左の一覧からプロジェクトを選んでください")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil { selection = store.projects.first?.id }
        }
        .confirmationDialog("「\(deleting?.name ?? "")」を一覧から削除しますか？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("削除", role: .destructive) {
                if let project = deleting {
                    store.remove(id: project.id)
                    if selection == project.id { selection = store.projects.first?.id }
                }
                deleting = nil
            }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: {
            Text("フォルダそのものは消えません。GitHub の紐づけもいっしょに外れます。")
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        let before = Set(store.projects.map(\.id))
        store.add(paths: panel.urls.map(\.path))
        if let added = store.projects.last(where: { !before.contains($0.id) }) { selection = added.id }
    }
}

/// 選んだプロジェクトの編集欄。文字欄は少し間を置いてまとめて保存し、確定・フォーカスが外れた時はすぐ書く。名前は空の間は保存しない。
private struct ProjectDetailForm: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var name = ""
    @State private var note = ""
    @FocusState private var focused: Field?

    private enum Field { case name, note }

    private var index: Int? { store.projects.firstIndex { $0.id == project.id } }

    var body: some View {
        Form {
            Section {
                TextField("名前", text: $name)
                    .focused($focused, equals: .name)
                    .onSubmit { store.flushPending() }
                    .onChange(of: name) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else {
                            store.cancelPending(key: key("name"))
                            return
                        }
                        store.scheduleProject(id: project.id, field: "name") { $0.name = trimmed }
                    }
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("名前を入れてください").font(.caption).foregroundStyle(.red)
                }
                LabeledContent("フォルダ") {
                    HStack(spacing: 8) {
                        Text(project.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Finder で表示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                        }
                        .controlSize(.small)
                    }
                }
                if !FileManager.default.fileExists(atPath: project.path) {
                    Text("このフォルダが見つかりません").font(.caption).foregroundStyle(.orange)
                }
                Picker("状態", selection: Binding(get: { project.status }, set: { status in
                    store.updateProject(id: project.id) { $0.status = status }
                })) {
                    ForEach(ProjectStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("メモ", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($focused, equals: .note)
                    .onChange(of: note) { _, value in
                        store.scheduleProject(id: project.id, field: "note") { $0.note = value }
                    }
            }
            Section {
                LabeledContent("並び順") {
                    HStack {
                        Button("上へ") { moveBy(-1) }.disabled(index == 0)
                        Button("下へ") { moveBy(1) }.disabled(index == store.projects.count - 1)
                    }
                }
            } footer: {
                Text("「+」の一覧はこの順に並びます。左の一覧はドラッグでも並べ替えられます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.isEditable)
        .onAppear {
            name = project.name
            note = project.note
        }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
        // 外で変わった時は欄を合わせ、溜めていた古い入力は捨てる（自分の保存では値が一致するので何もしない）。
        .onChange(of: project.name) { _, value in
            guard value != name.trimmingCharacters(in: .whitespaces) else { return }
            store.cancelPending(key: key("name"))
            name = value
        }
        .onChange(of: project.note) { _, value in
            guard value != note else { return }
            store.cancelPending(key: key("note"))
            note = value
        }
    }

    private func key(_ field: String) -> String { SettingsStore.projectKey(id: project.id, field: field) }

    private func moveBy(_ delta: Int) {
        guard let index else { return }
        let target = index + delta
        guard target >= 0, target < store.projects.count else { return }
        store.move(from: IndexSet(integer: index), to: delta > 0 ? target + 1 : target)
    }
}
