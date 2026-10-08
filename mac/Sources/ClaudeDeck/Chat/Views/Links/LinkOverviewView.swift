import SwiftUI
import MonitorKit

/// 中央: 全プロジェクト横断のリンク一覧。種類と「確認が必要なものだけ」で絞り、押すとブラウザで開いて最終確認日を記録する。編集はしない。
struct LinkOverviewView: View {
    let model: ChatModel
    @State private var filter: ProjectLinkKind?
    @State private var dueOnly = false

    private static let readableWidth: CGFloat = 900

    var body: some View {
        let visits = LinkVisitStore.shared
        let overview = LinkOverview.build(projects: SettingsStore.shared.projects, visits: visits.visits, today: visits.now,
                                          calendar: .autoupdatingCurrent, filter: filter, dueOnly: dueOnly)
        VStack(spacing: 0) {
            header(dueCount: overview.dueCount)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error = visits.saveError {
                        Text(error).font(ChatTheme.caption).foregroundStyle(ChatTheme.error)
                    }
                    if overview.sections.isEmpty { emptyState(dueCount: overview.dueCount) }
                    ForEach(overview.sections) { section in
                        LinkOverviewSectionView(model: model, section: section)
                    }
                }
                .padding(20)
                .frame(maxWidth: Self.readableWidth, alignment: .leading)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(ChatTheme.background)
    }

    private func header(dueCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ChatTheme.link)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(ChatTheme.inputSurface))
                VStack(alignment: .leading, spacing: 4) {
                    Text("リンク")
                        .font(ChatTheme.headline)
                        .foregroundStyle(ChatTheme.heading)
                    Text(dueCount > 0 ? "全プロジェクト・確認が必要なもの \(dueCount) 件" : "全プロジェクト")
                        .font(ChatTheme.caption)
                        .foregroundStyle(dueCount > 0 ? ChatTheme.permission : ChatTheme.secondary)
                }
                Spacer(minLength: 12)
            }
            HStack(spacing: 12) {
                Picker("種類", selection: $filter) {
                    Text("すべて").tag(ProjectLinkKind?.none)
                    ForEach(ProjectLinkKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(Optional(kind))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("確認が必要なものだけ", isOn: $dueOnly)
                    .toggleStyle(.checkbox)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.text)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .headerBackground()
        .zIndex(1)
    }

    private func emptyState(dueCount: Int) -> some View {
        let text: String
        if dueOnly {
            text = dueCount == 0 ? "確認が必要なリンクはありません" : "この種類に確認が必要なリンクはありません"
        } else if filter != nil {
            text = "この種類のリンクはありません"
        } else {
            text = "リンクがありません（ディレクトリの詳細か設定画面の「リンク」で登録します）"
        }
        return Text(text)
            .font(ChatTheme.body)
            .foregroundStyle(ChatTheme.secondary)
            .padding(.vertical, 8)
    }
}

/// プロジェクト 1 つ分の節（名前・パスの末尾・「詳細を開く」と各リンクの行）。
private struct LinkOverviewSectionView: View {
    let model: ChatModel
    let section: LinkOverviewSection

    var body: some View {
        let project = section.project
        let target = project.editorTarget
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ChatTheme.avatarColor(for: project.name))
                    .frame(width: 8, height: 8)
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatTheme.heading)
                    .lineLimit(1)
                Text(ProjectDirectories.pathTail(project.path))
                    .font(ChatTheme.mono)
                    .foregroundStyle(ChatTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if project.status != .active {
                    Text(project.status.label).font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
                }
                Spacer(minLength: 8)
                EditorNoteText(note: model.editors.notes[target.key])
                Button { model.selectDirectory(project.id) } label: {
                    Label("詳細を開く", systemImage: "folder")
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.link)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("このプロジェクトの詳細（リンクの編集はそちらで）")
            }
            ForEach(section.rows) { row in
                LinkOverviewRowView(row: row) {
                    model.editors.openLink(row.link, for: target, projectID: project.id)
                }
            }
        }
        .detailCard()
    }
}

/// 横断一覧の 1 行（確認のバッジ・種類・名前・URL・メモ・前回・ピン）。押すと開く。
private struct LinkOverviewRowView: View {
    let row: LinkOverviewRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let link = row.link
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if row.due { LinkDueBadge() }
                    LinkTitleParts(link: link, openable: true)
                    Spacer(minLength: 8)
                    Text(ProjectLinks.lastOpenedLabel(row.lastOpened))
                        .font(ChatTheme.caption)
                        .foregroundStyle(row.due ? ChatTheme.permission : ChatTheme.tertiary)
                        .fixedSize()
                    if link.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(ChatTheme.tertiary)
                            .help("見出しにボタンで出しています")
                    }
                }
                LinkDetailLine(link: link)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? ChatTheme.selectedRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ProjectLinks.help(for: link))
        .onHover { hovering = $0 }
    }
}

/// リンクの行の種類のアイコン・名前・URL（開けないものは薄く）。
struct LinkTitleParts: View {
    let link: ProjectLink
    let openable: Bool

    var body: some View {
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
    }
}

/// 「確認」の小さな黄色のバッジ（期日を過ぎてまだ開いていない）。
struct LinkDueBadge: View {
    var body: some View {
        Text("確認")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(ChatTheme.permission)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(ChatTheme.permission.opacity(0.16)))
            .fixedSize()
            .help("確認の日を過ぎてまだ開いていません")
    }
}

/// メモと「毎月 N 日に確認」の 2 行目（どちらも無ければ出さない）。
struct LinkDetailLine: View {
    let link: ProjectLink

    var body: some View {
        let parts = [link.resolvedNote.isEmpty ? nil : link.resolvedNote,
                     link.validReminderDay.map(LinkReminder.label(day:))].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " ・ "))
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 22)
        }
    }
}

/// 「ディレクトリ」の一覧の最上部に固定で出す「リンク」の行（検索で消えない）。
struct LinkOverviewListRow: View {
    let model: ChatModel

    var body: some View {
        let visits = LinkVisitStore.shared
        let selected = model.center == .links
        let due = LinkOverview.dueCount(projects: SettingsStore.shared.projects, visits: visits.visits, today: visits.now,
                                        calendar: .autoupdatingCurrent)
        Button { model.selectLinks() } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatTheme.link)
                    .frame(width: 18)
                Text("リンク")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChatTheme.text)
                Spacer(minLength: 4)
                if due > 0 {
                    Text("\(due)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ChatTheme.permission)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(ChatTheme.permission.opacity(0.16)))
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? ChatTheme.selectedRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(due > 0 ? "全プロジェクトのリンク（確認が必要なもの \(due) 件）" : "全プロジェクトのリンクをまとめて見る")
        .accessibilityLabel(due > 0 ? "リンク、確認が必要なもの \(due) 件" : "リンク")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.vertical, 1)
    }
}
