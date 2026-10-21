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

    private struct Scan: Equatable {
        var candidates: [String]
        var resolution: XcodeResolution
        /// 自動で見つかったもののプロジェクトからの相対パス。
        var detected: String?
    }

    private enum Mode: Hashable { case auto, specified, disabled }

    private var mode: Mode {
        switch project.xcode {
        case nil: return choosingPath ? .specified : .auto
        case .path: return .specified
        case .disabled: return .disabled
        }
    }

    var body: some View {
        Section {
            Picker("使い方", selection: Binding(get: { mode }, set: select)) {
                Text("自動").tag(Mode.auto)
                Text("指定する").tag(Mode.specified)
                Text("使わない").tag(Mode.disabled)
            }
            .pickerStyle(.segmented)
            if mode == .specified { pathRow }
            if let chooseProblem {
                Text(chooseProblem).font(.caption).foregroundStyle(.red)
            }
            status
        } header: {
            LinkageHeader(title: "Xcode", shows: "タブの「iPhone」・ボタンの「Xcode」「閉じる」")
        } footer: {
            Text("ディレクトリとルームの見出しの「Xcode」「閉じる」、詳細の「iPhone」のタブと iPhone のプレビューが開く .xcodeproj / .xcworkspace。自動はプロジェクトの浅い所から .xcworkspace を優先して最も浅いものを使います。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: project.xcode) { choosingPath = false }
        .task(id: "\(project.path)|\(String(describing: project.xcode))") {
            let project = project
            scan = await Task.detached(priority: .userInitiated) {
                let resolution = XcodeLinks.resolve(project: project, cwd: project.path)
                let detected = XcodeLinks.detect(in: project.path).path
                    .flatMap { try? XcodeLinks.relativePath(of: $0, in: project.path).get() }
                return Scan(candidates: XcodeLinks.candidates(in: project.path), resolution: resolution, detected: detected)
            }.value
        }
    }

    @ViewBuilder
    private var pathRow: some View {
        let current = project.xcode?.configuredPath
        let candidates = scan?.candidates ?? []
        let options = candidates + (current.map { candidates.contains($0) ? [] : [$0] } ?? [])
        HStack(spacing: 8) {
            if options.isEmpty {
                Text(scan == nil ? "探しています…" : "プロジェクトの浅い所に .xcodeproj / .xcworkspace が見つかりません")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Picker("場所", selection: Binding(get: { current ?? "" }, set: { save(.path($0)) })) {
                    if current == nil { Text("選んでください").tag("") }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            }
            Button("その他を選ぶ…") { choose() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let scan {
            let resolution = scan.resolution
            switch resolution.source {
            case .detected:
                Text(scan.detected.map { "自動で検出: \($0)" } ?? "見つかりません（「iPhone」のタブと「Xcode」「閉じる」は出ません）")
                    .font(.caption).foregroundStyle(.secondary)
            case .configured:
                if let problem = resolution.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("指定したものを使います").font(.caption).foregroundStyle(.secondary)
                }
            case .disabled:
                Text("「iPhone」のタブと「Xcode」「閉じる」のボタンを出しません")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
            guard project.xcode?.configuredPath == nil else { return }
            // 今自動で使っているものを初めの値にする（見出しの中身を変えずに固定できるように）。
            let candidates = scan?.candidates ?? []
            if let first = scan?.detected.flatMap({ candidates.contains($0) ? $0 : nil }) ?? candidates.first {
                save(.path(first))
            } else {
                // 候補が無い間は保存しない（自動のまま）。
                choosingPath = true
            }
        }
    }

    private func save(_ link: XcodeLink?) {
        chooseProblem = nil
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
