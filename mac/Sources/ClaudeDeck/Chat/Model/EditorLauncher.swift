import AppKit
import Observation
import MonitorKit

/// ボタンが働きかける先（ルームか、ディレクトリの詳細）。押した結果の一言は key ごとに出す。
struct EditorTarget: Hashable {
    let key: String
    let cwd: String
}

extension Room {
    var editorTarget: EditorTarget { EditorTarget(key: id.string, cwd: cwd) }
}

extension ManagedProject {
    var editorTarget: EditorTarget { EditorTarget(key: "project:\(id.uuidString)", cwd: path) }
}

/// 見出しの「VS Code」「GitHub」「リンク」「Xcode」「閉じる」と詳細の「Finder」。押した結果は押した先ごとに数秒だけ出す。
@MainActor
@Observable
final class EditorLauncher {
    /// `EditorTarget.key` → 押した結果。数秒で消す。
    private(set) var notes: [String: EditorNote] = [:]
    /// Xcode に閉じるよう頼んでいる最中の `EditorTarget.key`。二度押しさせない。
    private(set) var closingXcode: Set<String> = []
    /// owner の種類を問い合わせている最中の `EditorTarget.key`。二度押しで同じ先を二度開かない。
    private(set) var openingGitHub: Set<String> = []

    @ObservationIgnored private var xcodeProjects: [String: URL?] = [:]
    @ObservationIgnored private let githubOwners = GitHubOwnerKindResolver()

    /// 結果は cwd で覚えるので、同じ場所を指すルームと詳細は同じ答えを引く。
    func xcodeProject(for target: EditorTarget) -> URL? {
        if let cached = xcodeProjects[target.cwd] { return cached }
        let found = XcodeFinder.find(in: target.cwd).map { URL(fileURLWithPath: $0) }
        xcodeProjects[target.cwd] = found
        return found
    }

    func openInVSCode(_ target: EditorTarget) {
        let folder = URL(fileURLWithPath: target.cwd, isDirectory: true)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            showNote(.failed("Visual Studio Code が見つかりません"), for: target.key)
            return
        }
        open(folder, with: app, for: target.key)
    }

    func revealInFinder(_ target: EditorTarget) {
        guard FileManager.default.fileExists(atPath: target.cwd) else {
            showNote(.failed("フォルダが見つかりません: \(target.cwd)"), for: target.key)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.cwd, isDirectory: true)])
    }

    func openInXcode(_ target: EditorTarget) {
        guard let url = xcodeProject(for: target) else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            showNote(.failed("Xcode が見つかりません"), for: target.key)
            return
        }
        open(url, with: app, for: target.key)
    }

    /// Xcode 本体は終了させず、この先のワークスペースだけを閉じる。
    func closeInXcode(_ target: EditorTarget) {
        let key = target.key
        guard let url = xcodeProject(for: target), !closingXcode.contains(key) else { return }
        closingXcode.insert(key)
        notes[key] = nil
        Task { @MainActor [weak self] in
            let outcome = await XcodeClose.close(path: url.path)
            guard let self else { return }
            self.closingXcode.remove(key)
            self.showNote(outcome, for: key)
        }
    }

    /// 設定の変化を見出しへすぐ映すため、描画の中で毎回引く（SettingsStore は Observable）。
    func githubDestinations(for target: EditorTarget) -> [GitHubDestination] {
        guard let link = matchedProject(target)?.github else { return [] }
        return GitHubDestination.all(for: link)
    }

    func openOnGitHub(_ destination: GitHubDestination, for target: EditorTarget) {
        let key = target.key
        guard !openingGitHub.contains(key) else { return }
        guard case .board = destination else {
            openGitHubURL(destination.url(ownerKind: nil), unknownKind: false, for: key)
            return
        }
        openingGitHub.insert(key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kind = await self.githubOwners.kind(of: destination.owner)
            self.openingGitHub.remove(key)
            self.openGitHubURL(destination.url(ownerKind: kind), unknownKind: kind == nil, for: key)
        }
    }

    /// 紐づいたプロジェクトのリンクのうち開けるもの（設定の変化を見出しへすぐ映すため、描画の中で毎回引く）。
    func projectLinks(for target: EditorTarget) -> [ProjectLink] {
        ProjectLinks.openable(matchedProject(target)?.links ?? [])
    }

    /// 見出しに単独のボタンで出すピン留めのリンク（描画の中で毎回引く）。
    func pinnedLinks(for target: EditorTarget) -> [ProjectLink] {
        ProjectLinks.pinned(matchedProject(target)?.links ?? [])
    }

    /// 紐づいたプロジェクトの id（最終確認日の記録に使う）。
    func projectID(for target: EditorTarget) -> UUID? {
        matchedProject(target)?.id
    }

    /// 場所が一致するか配下にある登録プロジェクト（いちばん深いもの）。
    private func matchedProject(_ target: EditorTarget) -> ManagedProject? {
        ProjectMatcher.project(for: target.cwd, in: SettingsStore.shared.projects)
    }

    /// 設定が外で書き換わっていても開く直前に URL を確かめる。開けた時だけ最終確認日を記録する（どの経路から開いてもここを通る）。
    func openLink(_ link: ProjectLink, for target: EditorTarget, projectID: UUID? = nil) {
        guard let url = ProjectLinks.url(from: link.url) else {
            showNote(.failed("「\(link.name)」の URL が開ける形ではありません（http / https のアドレスにしてください）"), for: target.key)
            return
        }
        guard openInBrowser(url, for: target.key) else { return }
        if let projectID = projectID ?? self.projectID(for: target) {
            LinkVisitStore.shared.record(projectID: projectID, link: link)
        }
        showNote(.opened, for: target.key)
    }

    private func openGitHubURL(_ url: URL?, unknownKind: Bool, for key: String) {
        guard let url else {
            showNote(.failed("GitHub の URL を組み立てられません（設定の owner / リポジトリを確かめてください）"), for: key)
            return
        }
        guard openInBrowser(url, for: key) else { return }
        // 組織の owner だと個人の形の URL は 404 になるので、推測で開いたことを伝える。
        showNote(unknownKind ? .openedWithNote("owner の種類を確かめられなかったため、個人の Project として開きました") : .opened, for: key)
    }

    /// 既定のブラウザで開く。開けなければ理由を出して false。
    private func openInBrowser(_ url: URL, for key: String) -> Bool {
        guard NSWorkspace.shared.open(url) else {
            showNote(.failed("ブラウザで開けませんでした: \(url.absoluteString)"), for: key)
            return false
        }
        return true
    }

    private func open(_ url: URL, with app: URL, for key: String) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let outcome: EditorOutcome = error.map { .failed("開けませんでした: \($0.localizedDescription)") } ?? .opened
            Task { @MainActor [weak self] in self?.showNote(outcome, for: key) }
        }
    }

    private func showNote(_ outcome: EditorOutcome, for key: String) {
        let note = EditorNote(outcome: outcome)
        notes[key] = note
        // 失敗は読み切れるよう長めに残す。
        let delay: Duration = outcome.isFailure ? .seconds(8) : .seconds(4)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // 後から出した結果を古いタイマーで消さない。
            if self?.notes[key]?.id == note.id { self?.notes[key] = nil }
        }
    }
}

struct EditorNote: Equatable {
    let id = UUID()
    let outcome: EditorOutcome
}
