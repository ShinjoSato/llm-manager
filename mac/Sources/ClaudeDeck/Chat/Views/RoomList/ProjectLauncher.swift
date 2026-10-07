import SwiftUI
import MonitorKit

/// 「+」の中身: 登録済みプロジェクトから選んで起動する。一覧の追加・削除もここで行う（設定画面と同じデータ）。
struct ProjectLauncher: View {
    let onPick: (ManagedProject) -> Void
    private let store = SettingsStore.shared
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新しいルーム")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ChatTheme.heading)
            TextField("", text: $filter, prompt: Text("プロジェクトを絞り込む").foregroundStyle(ChatTheme.tertiary))
                .textFieldStyle(.plain)
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatTheme.inputBorder))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { project in
                        HStack(spacing: 4) {
                            Button { onPick(project) } label: {
                                HStack(spacing: 8) {
                                    RoomAvatar(name: project.name, size: 26, badge: ProjectBadge.resolve(project: project))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(project.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatTheme.text)
                                        Text(project.path).font(.system(size: 11)).foregroundStyle(ChatTheme.tertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(project.path)
                            Menu {
                                actions(for: project)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ChatTheme.secondary)
                                    .frame(width: 24, height: 24)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Finder で表示・一覧から削除")
                        }
                        .contextMenu { actions(for: project) }
                    }
                    if filtered.isEmpty {
                        Text("プロジェクトがありません").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary).padding(6)
                    }
                    if let problem = store.problem {
                        Text("設定を読めないため一覧を変えられません: \(problem)")
                            .font(ChatTheme.caption).foregroundStyle(ChatTheme.permission)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                    }
                    if let message = store.notice ?? store.saveError {
                        Text(message)
                            .font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                    }
                }
            }
            .frame(height: min(CGFloat(max(filtered.count, 1)) * 44, 320))
            Divider().overlay(ChatTheme.border)
            HStack {
                Button { addFolder() } label: {
                    Label("フォルダを追加…", systemImage: "folder.badge.plus")
                }
                .help("Claude Code を起動するプロジェクトフォルダを一覧に追加")
                .disabled(!store.isEditable)
                Spacer()
                Button { SettingsWindow.show(tab: .projects) } label: {
                    Label("設定を開く…", systemImage: "gearshape")
                }
                .help("プロジェクトの名前・状態・メモ・リンク・GitHub の紐づけを編集する")
            }
            .buttonStyle(.plain)
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.secondary)
        }
        .padding(12)
        .frame(width: 360)
        .background(ChatTheme.sidebar)
        .onAppear { store.reloadIfChanged() }
    }

    @ViewBuilder
    private func actions(for project: ManagedProject) -> some View {
        Button("Finder で表示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        }
        Divider()
        Button("一覧から削除", role: .destructive) {
            store.remove(id: project.id)
        }
        .disabled(!store.isEditable)
    }

    private var filtered: [ManagedProject] {
        let terms = filter.split(whereSeparator: \.isWhitespace)
        return store.projects.filter { p in
            terms.allSatisfy { "\(p.name) \(p.path)".range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        store.add(paths: panel.urls.map(\.path))
    }
}
