import MonitorKit
import SwiftUI

/// 欄の下に出す、保存できない理由の一覧。
struct SettingsProblems: View {
    let problems: [String]

    var body: some View {
        ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
    }
}

/// 項目名の横の ⓘ。ホバーで説明を出し、押すと同じ説明をポップオーバーで出す。
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel("説明")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(12)
        }
    }
}

/// 節の見出し（名前と ⓘ）。
struct SettingsSectionHeader: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(text: info)
        }
    }
}

/// 行の下に添える一言（検証の問題など）。
struct SettingsNote: Equatable {
    var text: String
    var isError = true
}

/// 設定の 1 行: 名前と ⓘ・今の値の要約・操作。値が無い時は要約を控えめに出す。
struct SettingsItemLabel<Actions: View>: View {
    let title: String
    var info: String?
    let summary: String
    var isEmpty = false
    var note: SettingsNote?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(title)
                    if let info { InfoButton(text: info) }
                }
                .frame(width: 92, alignment: .leading)
                Text(summary)
                    .foregroundStyle(isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary)
                Spacer(minLength: 8)
                actions()
            }
            if let note {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.isError ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 100)
            }
        }
    }
}

extension SettingsItemLabel where Actions == EmptyView {
    init(title: String, info: String? = nil, summary: String, isEmpty: Bool = false, note: SettingsNote? = nil) {
        self.init(title: title, info: info, summary: summary, isEmpty: isEmpty, note: note) { EmptyView() }
    }
}

extension View {
    /// 設定の 1 行の文字欄（見出しを隠して枠を付け、⏎ で `onSubmit`）。
    func settingsField(onSubmit: @escaping () -> Void) -> some View {
        labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(onSubmit)
    }
}

extension SettingsStore {
    /// そのフォルダの登録プロジェクト。無ければ名前だけの仮のプロジェクト。
    func project(atPath path: String, orNamed name: String) -> ManagedProject {
        projects.first { $0.path == path } ?? ManagedProject(name: name, path: path)
    }
}
