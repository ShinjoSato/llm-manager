import MonitorKit
import SwiftUI

/// 欄の下に出す、保存できない理由の一覧。
struct SettingsProblems: View {
    let problems: [String]

    var body: some View {
        ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
    }
}

/// プロジェクトの画面の紐づけの節の見出し（見出しに何が出るかを添える）。
struct LinkageHeader: View {
    let title: String
    let shows: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("紐づけ · \(title)")
            Text("見出しの\(shows)").font(.caption).foregroundStyle(.secondary)
        }
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
