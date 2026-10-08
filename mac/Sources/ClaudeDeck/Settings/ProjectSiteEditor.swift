import AppKit
import MonitorKit
import SwiftUI

/// プロジェクトの LP の場所。空なら自動で探し、指定はプロジェクトからの相対パス（外は指せない）。正しい間だけ保存する。
struct ProjectSiteEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    @State private var text = ""
    @State private var lookup: SiteLookup?
    @FocusState private var focused: Bool

    private var key: String { SettingsStore.projectKey(id: project.id, field: "site") }
    private var problem: String? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SiteLocator.normalizedRelativePath(text).failure
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                TextField("場所", text: $text, prompt: Text("空なら自動（例: site）"))
                    .focused($focused)
                    .onSubmit { store.flushPending() }
                Button("フォルダを選ぶ…") { chooseFolder() }
                    .controlSize(.small)
                if project.site != nil {
                    Button("自動に戻す") { text = "" }
                        .controlSize(.small)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let lookup {
                status(lookup)
            }
        } header: {
            Text("サイト")
        } footer: {
            Text("ディレクトリの詳細でプレビューする LP（Next.js の静的書き出し `out/` のあるフォルダ）。空ならプロジェクト直下と浅いサブフォルダから探します。")
                .font(.caption).foregroundStyle(.secondary)
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
            lookup = await Task.detached(priority: .userInitiated) { SiteLocator.lookup(project: project) }.value
        }
    }

    @ViewBuilder
    private func status(_ lookup: SiteLookup) -> some View {
        if let reason = lookup.problem {
            Text(reason).font(.caption).foregroundStyle(.orange)
        } else if let location = lookup.location {
            let exported = FileManager.default.fileExists(atPath: location.exportIndex)
            let place = location.relativePath == "." ? "プロジェクト直下" : location.relativePath
            Text("\(location.source == .configured ? "指定" : "自動で検出"): \(place)（\(exported ? "書き出しあり" : "out/ はまだありません")）")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("見つかりません").font(.caption).foregroundStyle(.secondary)
        }
        if project.site == nil, lookup.candidates.count > 1 {
            HStack(spacing: 6) {
                Text("候補:").font(.caption).foregroundStyle(.secondary)
                ForEach(lookup.candidates, id: \.self) { candidate in
                    Button(candidate == "." ? "直下" : candidate) { text = candidate }
                        .controlSize(.small)
                }
            }
        }
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
            return
        }
        text = relative
        store.flushPending()
    }
}
