import AppKit
import MonitorKit
import SwiftUI

/// プロジェクトの LP の場所。空なら自動で探し、指定はプロジェクトからの相対パス（外は指せない）。正しい間だけ保存する。
struct ProjectSiteEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var text = ""
    @State private var lookup: SiteLookup?
    /// 書き出し（out/index.html）があるか。探した時に一緒に見る。
    @State private var exported = false
    @State private var expanded = false
    @FocusState private var focused: Bool

    private var key: String { SettingsStore.projectKey(id: project.id, field: "site") }
    private var problem: String? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SiteLocator.normalizedRelativePath(text).failure
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            HStack(spacing: 8) {
                TextField("場所", text: $text, prompt: Text("空なら自動（例: site）"))
                    .settingsField { store.flushPending() }
                    .focused($focused)
                if project.site != nil {
                    Button("自動に戻す") { text = "" }
                        .controlSize(.small)
                }
            }
            if project.site == nil, let lookup, lookup.candidates.count > 1 {
                HStack(spacing: 6) {
                    Text("候補:").font(.caption).foregroundStyle(.secondary)
                    ForEach(lookup.candidates, id: \.self) { candidate in
                        Button(candidate == "." ? "直下" : candidate) { text = candidate }
                            .controlSize(.small)
                    }
                }
            }
        } label: {
            SettingsItemLabel(title: "サイト",
                              info: "詳細の「サイト」のタブでプレビューする LP（Next.js の静的書き出し out/ のあるフォルダ）。空ならプロジェクト直下と浅いサブフォルダから探します。",
                              summary: LinkageSummary.site(configured: project.site, lookup: lookup, exported: exported),
                              isEmpty: project.site == nil && lookup != nil && lookup?.location == nil,
                              note: note) {
                Button("フォルダを選ぶ…") { chooseFolder() }
                    .controlSize(.small)
            }
        }
        .onAppear { text = project.site?.path ?? "" }
        .onChange(of: text) { _, value in commit(value) }
        // 外で変わった時は欄を外の値に合わせる（溜めていた入力はストアが捨てて案内を出す。自分の保存では値が一致するので何もしない）。
        .onChange(of: project.site) { _, site in
            guard site != pendingValue(text) else { return }
            store.cancelPending(key: key)
            text = site?.path ?? ""
        }
        .onChange(of: focused) { store.flushPending() }
        .onDisappear { store.flushPending(force: true) }
        .task(id: "\(project.path)|\(project.site?.path ?? "")") {
            let project = project
            let found = await Task.detached(priority: .userInitiated) { () -> (SiteLookup, Bool) in
                let lookup = SiteLocator.lookup(project: project)
                return (lookup, lookup.location.map { FileManager.default.fileExists(atPath: $0.exportIndex) } ?? false)
            }.value
            lookup = found.0
            exported = found.1
        }
    }

    /// 行に添える問題（入力の形・指定した先が使えない理由）。
    private var note: SettingsNote? {
        if let problem { return SettingsNote(text: problem) }
        if let reason = lookup?.problem { return SettingsNote(text: reason, isError: false) }
        return nil
    }

    /// 空は自動（キーを消す）、正しい相対パスは指定として保存。不正な間は保存しない。
    private func pendingValue(_ value: String) -> ProjectSite? {
        SiteLocator.normalizedRelativePath(value).path.map(ProjectSite.init(path:))
    }

    private func commit(_ value: String) {
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            store.scheduleProject(id: project.id, field: "site", \.site, nil)
            return
        }
        guard let site = pendingValue(value) else {
            store.cancelPending(key: key)
            return
        }
        store.scheduleProject(id: project.id, field: "site", \.site, site)
    }

    private func chooseFolder() {
        guard let url = SystemActions.choose(folders: true, multiple: false, prompt: "選ぶ",
                                             directory: URL(fileURLWithPath: project.path, isDirectory: true)).first else { return }
        guard let relative = SiteLocator.relativePath(of: url.path, in: project.path) else {
            NSSound.beep()
            text = url.path
            expanded = true
            return
        }
        text = relative
        store.flushPending()
    }
}
