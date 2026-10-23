import AppKit
import MonitorKit
import SwiftUI

/// プロジェクトの Xcode の紐づけ: 自動（見つかったもの）・指定する（プロジェクトの中から選ぶ）・使わない。選んだ時だけ保存する。
struct ProjectXcodeEditor: View {
    let store: SettingsStore
    let project: ManagedProject
    /// 走査の結果（nil は走査中）。
    @State private var scan: Scan?
    /// 「指定する」を選んだが、まだ候補を選んでいない（保存していない）。
    @State private var choosingPath = false
    @State private var chooseProblem: String?
    @State private var expanded = false

    private struct Scan: Equatable {
        var candidates: [String]
        var resolution: XcodeResolution
        /// 自動で見つかったもののプロジェクトからの相対パス。
        var detected: String?
    }

    private enum Mode: Hashable { case auto, specified, disabled }

    private var mode: Mode {
        // 保存前の「指定する」は今の紐づけ（自動・使わない）より先に見る（候補が無くても「その他を選ぶ…」へ進めるように）。
        if choosingPath { return .specified }
        switch project.xcode {
        case nil: return .auto
        case .path: return .specified
        case .disabled: return .disabled
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            pathRow
        } label: {
            SettingsItemLabel(title: "Xcode",
                              info: "見出しの「Xcode」「閉じる」と、詳細の「iPhone」のタブ・プレビューが開く .xcodeproj / .xcworkspace。自動はプロジェクトの浅い所から .xcworkspace を優先して最も浅いものを使います。開くと場所を選べます。",
                              summary: LinkageSummary.xcode(project.xcode, detected: scan?.detected, scanned: scan != nil, choosing: choosingPath),
                              isEmpty: project.xcode == .disabled || (project.xcode == nil && scan != nil && scan?.detected == nil),
                              notes: notes) {
                Picker("使い方", selection: Binding(get: { mode }, set: select)) {
                    Text("自動").tag(Mode.auto)
                    Text("指定").tag(Mode.specified)
                    Text("使わない").tag(Mode.disabled)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .onChange(of: project.xcode) { choosingPath = false }
        .task(id: "\(project.path)|\(String(describing: project.xcode))") {
            let project = project
            let result = await Task.detached(priority: .userInitiated) {
                let resolution = XcodeLinks.resolve(project: project, cwd: project.path)
                let detected = XcodeLinks.detect(in: project.path).path
                    .flatMap { try? XcodeLinks.relativePath(of: $0, in: project.path).get() }
                return Scan(candidates: XcodeLinks.candidates(in: project.path), resolution: resolution, detected: detected)
            }.value
            guard !Task.isCancelled else { return }
            scan = result
        }
    }

    @ViewBuilder
    private var pathRow: some View {
        let current = project.xcode?.configuredPath
        let candidates = scan?.candidates ?? []
        let options = candidates + (current.map { candidates.contains($0) ? [] : [$0] } ?? [])
        HStack(spacing: 8) {
            if options.isEmpty {
                Text(scan == nil ? LinkageSummary.searching : "浅い所に .xcodeproj / .xcworkspace が見つかりません")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Picker("場所", selection: Binding(get: { current ?? "" }, set: { value in
                    // 「選んでください」（空）や形の正しくないものは保存しない。
                    guard let path = XcodeLinks.normalizedPath(value) else { return }
                    save(.path(path))
                })) {
                    if current == nil { Text("選んでください").tag("") }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            }
            Button("その他を選ぶ…") { choose() }
                .controlSize(.small)
        }
    }

    /// 行に添える問題（選べなかった理由・指定した先が使えない理由）。
    private var notes: [SettingsNote] {
        if let chooseProblem { return [SettingsNote(text: chooseProblem)] }
        if let scan, scan.resolution.source == .configured, let problem = scan.resolution.problem {
            return [SettingsNote(text: problem, isError: false)]
        }
        return []
    }

    private func select(_ next: Mode) {
        chooseProblem = nil
        switch next {
        case .auto:
            choosingPath = false
            if project.xcode != nil { save(nil) }
        case .disabled:
            choosingPath = false
            save(.disabled)
        case .specified:
            expanded = true
            guard project.xcode?.configuredPath == nil else { return }
            // 今自動で使っているものを初めの値にする（見出しの中身を変えずに固定できるように）。
            let candidates = scan?.candidates ?? []
            if let first = scan?.detected.flatMap({ candidates.contains($0) ? $0 : nil }) ?? candidates.first {
                save(.path(first))
            } else {
                // 候補が無い間は保存しない（自動のまま）。
                choosingPath = true
                expanded = true
            }
        }
    }

    private func save(_ link: XcodeLink?) {
        chooseProblem = nil
        choosingPath = false
        store.updateProject(id: project.id) { $0.xcode = link }
    }

    private func choose() {
        guard let url = SystemActions.choose(folders: false, multiple: false, prompt: "選ぶ",
                                             message: "このプロジェクトの中の .xcodeproj / .xcworkspace を選んでください",
                                             directory: URL(fileURLWithPath: project.path, isDirectory: true)).first else { return }
        switch XcodeLinks.relativePath(of: url.path, in: project.path) {
        case .success(let relative):
            save(.path(relative))
        case .failure(let failure):
            NSSound.beep()
            chooseProblem = failure.message
        }
    }
}
