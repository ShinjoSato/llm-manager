import AppKit
import Observation
import MonitorKit

/// 見出しの「VS Code」「GitHub」「リンク」「Xcode」「閉じる」。押した結果はルームごとに数秒だけ出す。
@MainActor
@Observable
final class EditorLauncher {
    /// ルーム → 見出しの「VS Code / GitHub / リンク / Xcode / 閉じる」の結果。数秒で消す。
    private(set) var notes: [RoomID: EditorNote] = [:]
    /// Xcode に閉じるよう頼んでいる最中のルーム。二度押しさせない。
    private(set) var closingXcode: Set<RoomID> = []
    /// owner の種類を問い合わせている最中のルーム。見出しに出し、二度押しで同じ先を二度開かない。
    private(set) var openingGitHub: Set<RoomID> = []

    @ObservationIgnored private var xcodeProjects: [String: URL?] = [:]
    @ObservationIgnored private let githubOwners = GitHubOwnerKindResolver()

    func xcodeProject(for room: Room) -> URL? {
        if let cached = xcodeProjects[room.cwd] { return cached }
        let found = XcodeFinder.find(in: room.cwd).map { URL(fileURLWithPath: $0) }
        xcodeProjects[room.cwd] = found
        return found
    }

    func openInVSCode(_ room: Room) {
        let folder = URL(fileURLWithPath: room.cwd, isDirectory: true)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            showNote(.failed("Visual Studio Code が見つかりません"), for: room.id)
            return
        }
        open(folder, with: app, for: room.id)
    }

    func openInXcode(_ room: Room) {
        guard let url = xcodeProject(for: room) else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            showNote(.failed("Xcode が見つかりません"), for: room.id)
            return
        }
        open(url, with: app, for: room.id)
    }

    /// Xcode 本体は終了させず、このルームのワークスペースだけを閉じる。
    func closeInXcode(_ room: Room) {
        guard let url = xcodeProject(for: room), !closingXcode.contains(room.id) else { return }
        let roomId = room.id
        closingXcode.insert(roomId)
        notes[roomId] = nil
        Task { @MainActor [weak self] in
            let outcome = await XcodeClose.close(path: url.path)
            guard let self else { return }
            self.closingXcode.remove(roomId)
            self.showNote(outcome, for: roomId)
        }
    }

    /// 設定の変化を見出しへすぐ映すため、描画の中で毎回引く（SettingsStore は Observable）。
    func githubDestinations(for room: Room) -> [GitHubDestination] {
        guard let link = ProjectMatcher.project(for: room.cwd, in: SettingsStore.shared.projects)?.github else { return [] }
        return GitHubDestination.all(for: link)
    }

    func openOnGitHub(_ destination: GitHubDestination, for room: Room) {
        let roomId = room.id
        guard !openingGitHub.contains(roomId) else { return }
        guard case .board = destination else {
            openGitHubURL(destination.url(ownerKind: nil), unknownKind: false, for: roomId)
            return
        }
        openingGitHub.insert(roomId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kind = await self.githubOwners.kind(of: destination.owner)
            self.openingGitHub.remove(roomId)
            self.openGitHubURL(destination.url(ownerKind: kind), unknownKind: kind == nil, for: roomId)
        }
    }

    /// 紐づいたプロジェクトのリンクのうち開けるもの（設定の変化を見出しへすぐ映すため、描画の中で毎回引く）。
    func projectLinks(for room: Room) -> [ProjectLink] {
        guard let project = ProjectMatcher.project(for: room.cwd, in: SettingsStore.shared.projects) else { return [] }
        return ProjectLinks.openable(project.links)
    }

    /// 設定が外で書き換わっていても開く直前に URL を確かめる。
    func openLink(_ link: ProjectLink, for room: Room) {
        guard let url = ProjectLinks.url(from: link.url) else {
            showNote(.failed("「\(link.name)」の URL が開ける形ではありません（http / https のアドレスにしてください）"), for: room.id)
            return
        }
        guard NSWorkspace.shared.open(url) else {
            showNote(.failed("ブラウザで開けませんでした: \(url.absoluteString)"), for: room.id)
            return
        }
        showNote(.opened, for: room.id)
    }

    private func openGitHubURL(_ url: URL?, unknownKind: Bool, for roomId: RoomID) {
        guard let url else {
            showNote(.failed("GitHub の URL を組み立てられません（設定の owner / リポジトリを確かめてください）"), for: roomId)
            return
        }
        guard NSWorkspace.shared.open(url) else {
            showNote(.failed("ブラウザで開けませんでした: \(url.absoluteString)"), for: roomId)
            return
        }
        // 組織の owner だと個人の形の URL は 404 になるので、推測で開いたことを伝える。
        showNote(unknownKind ? .openedWithNote("owner の種類を確かめられなかったため、個人の Project として開きました") : .opened, for: roomId)
    }

    private func open(_ url: URL, with app: URL, for roomId: RoomID) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let outcome: EditorOutcome = error.map { .failed("開けませんでした: \($0.localizedDescription)") } ?? .opened
            Task { @MainActor [weak self] in self?.showNote(outcome, for: roomId) }
        }
    }

    private func showNote(_ outcome: EditorOutcome, for roomId: RoomID) {
        let note = EditorNote(outcome: outcome)
        notes[roomId] = note
        // 失敗は読み切れるよう長めに残す。
        let delay: Duration = outcome.isFailure ? .seconds(8) : .seconds(4)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // 後から出した結果を古いタイマーで消さない。
            if self?.notes[roomId]?.id == note.id { self?.notes[roomId] = nil }
        }
    }
}

struct EditorNote: Equatable {
    let id = UUID()
    let outcome: EditorOutcome
}
