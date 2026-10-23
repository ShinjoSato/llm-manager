import Foundation

// `GET /v1/projects` の中身を設定と「ディレクトリ」の振り分けから作る。表示に要る分だけで、フォルダのパス・メモ・コマンド等は載せない。

extension RemoteProjectList {
    /// 「ディレクトリ」と同じ並び（進行中 → 休止・保管）とルームの振り分けで作る。
    public init(directories: [ProjectDirectory]) {
        self.init(projects: directories.map(RemoteProject.init(directory:)))
    }
}

extension RemoteProject {
    public init(directory: ProjectDirectory) {
        let project = directory.project
        self.init(id: project.id.uuidString, name: project.name,
                  status: RemoteProjectStatus(rawValue: project.status.rawValue) ?? .unknown,
                  github: project.github.flatMap(RemoteGitHubSummary.init(link:)),
                  links: RemoteProjectLink.openable(project.links), roomIds: directory.ids)
    }
}

extension RemoteGitHubSummary {
    /// owner の無い紐づけは出さない。
    public init?(link: GitHubLink) {
        let owner = link.owner.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty else { return nil }
        let repo = link.repo?.trimmingCharacters(in: .whitespaces)
        self.init(owner: owner, repo: repo?.isEmpty == true ? nil : repo, projectNumber: link.projectNumber)
    }
}

extension RemoteProjectLink {
    /// mac の見出しで開けるもの（`ProjectLinks.openable`）だけを、開く時と同じ整えた URL で。
    public static func openable(_ links: [ProjectLink]) -> [RemoteProjectLink] {
        ProjectLinks.openable(links).compactMap { link in
            guard let url = ProjectLinks.url(from: link.url) else { return nil }
            return RemoteProjectLink(name: link.name.trimmingCharacters(in: .whitespaces), url: url.absoluteString,
                                     kind: RemoteLinkKind(rawValue: link.resolvedKind.rawValue) ?? .other,
                                     pinned: link.isPinned, note: ProjectLinks.noteToSave(link.resolvedNote))
        }
    }
}
