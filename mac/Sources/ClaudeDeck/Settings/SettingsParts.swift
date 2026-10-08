import MonitorKit
import SwiftUI

/// 欄の下に出す、保存できない理由の一覧。
struct SettingsProblems: View {
    let problems: [String]

    var body: some View {
        ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
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
