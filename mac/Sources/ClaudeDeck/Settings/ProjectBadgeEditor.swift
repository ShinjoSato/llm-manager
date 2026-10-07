import MonitorKit
import SwiftUI

/// プロジェクトの印（色とアイコン）。選ぶと即時に保存し、「自動」「既定」でキーを消す。
struct ProjectBadgeEditor: View {
    let store: SettingsStore
    let project: ManagedProject

    private var badge: ProjectBadge { ProjectBadge.resolve(project: project) }
    private var chosenColor: ProjectColor? { project.color.flatMap(ProjectColor.init(rawValue:)) }
    private var chosenIcon: String? {
        guard let icon = project.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty else { return nil }
        return icon
    }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ProjectBadgeView(badge: badge, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.body.weight(.medium))
                    Text("\(chosenColor == nil ? "自動（\(badge.colorKey.label)）" : badge.colorKey.label)・\(chosenIcon == nil ? "既定（\(badge.symbol)）" : badge.symbol)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("色") {
                HStack(spacing: 6) {
                    swatch(nil)
                    ForEach(ProjectColor.allCases) { swatch($0) }
                }
            }
            if let problem = ProjectBadge.colorProblem(project.color) {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("アイコン") {
                VStack(alignment: .trailing, spacing: 6) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 4)], spacing: 4) {
                        ForEach(ProjectBadge.symbolChoices, id: \.self) { symbolCell($0) }
                    }
                    if chosenIcon != nil {
                        Button("既定に戻す") { store.updateProject(id: project.id) { $0.icon = nil } }
                            .controlSize(.small)
                    }
                }
            }
            if let problem = ProjectBadge.iconProblem(project.icon) {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if let icon = chosenIcon, icon != badge.symbol {
                Text("「\(icon)」は SF Symbol として見つからないため、既定の \(ProjectBadge.defaultSymbol) で出します")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("アイコンと色")
        } footer: {
            Text("ディレクトリ一覧・詳細の見出し・「+」の一覧に出る印です。「自動」は名前から色を決めます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 色のスウォッチ。nil は「自動」（名前から決めた色を点線の縁で出す）。
    private func swatch(_ key: ProjectColor?) -> some View {
        let color = ChatTheme.avatarColor(for: key ?? ProjectBadge.defaultColor(for: project.name))
        let selected = key == chosenColor
        return Button {
            store.updateProject(id: project.id) { $0.color = key?.rawValue }
        } label: {
            ZStack {
                Circle().fill(color.opacity(key == nil ? 0.35 : 1))
                if key == nil {
                    Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(key == nil ? color : Color.white)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-3))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(key?.label ?? "自動（名前から決める）")
        .accessibilityLabel(key?.label ?? "自動")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// アイコンのセル。既定のアイコンを押した時はキーを消す。
    private func symbolCell(_ symbol: String) -> some View {
        let selected = symbol == badge.symbol
        return Button {
            store.updateProject(id: project.id) { $0.icon = symbol == ProjectBadge.defaultSymbol ? nil : symbol }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: selected ? 1.5 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol == ProjectBadge.defaultSymbol ? "\(symbol)（既定）" : symbol)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
