import Foundation

/// 横断のリンク一覧の 1 行。
public struct LinkOverviewRow: Sendable, Equatable, Identifiable {
    public var projectID: UUID
    /// 設定の `links` の中の位置。
    public var index: Int
    public var link: ProjectLink
    public var lastOpened: Date?
    public var due: Bool

    public var id: String { "\(projectID.uuidString)|\(index)" }
}

/// プロジェクトごとの節。
public struct LinkOverviewSection: Sendable, Equatable, Identifiable {
    public var project: ManagedProject
    public var rows: [LinkOverviewRow]

    public var id: UUID { project.id }
}

/// 全プロジェクト横断のリンク一覧の組み立て。
public struct LinkOverview: Sendable, Equatable {
    /// 絞り込みの後に残った節（リンクのあるプロジェクトだけ・設定の順・status は問わない）。
    public var sections: [LinkOverviewSection]
    /// 絞り込む前の、確認が必要なリンクの総数。
    public var dueCount: Int

    public static func build(projects: [ManagedProject], visits: LinkVisits, today: Date, calendar: Calendar,
                             filter: ProjectLinkKind? = nil, dueOnly: Bool = false) -> LinkOverview {
        var dueCount = 0
        var seen = Set<UUID>()
        let sections: [LinkOverviewSection] = projects.compactMap { project in
            guard seen.insert(project.id).inserted else { return nil }
            let rows = rows(of: project, visits: visits, today: today, calendar: calendar)
            dueCount += rows.filter(\.due).count
            let kept = rows.filter { (filter == nil || $0.link.resolvedKind == filter) && (!dueOnly || $0.due) }
            return kept.isEmpty ? nil : LinkOverviewSection(project: project, rows: kept)
        }
        return LinkOverview(sections: sections, dueCount: dueCount)
    }

    /// 開けるリンクだけを設定の順で（位置は元の `links` の中のもの）。
    public static func rows(of project: ManagedProject, visits: LinkVisits, today: Date, calendar: Calendar) -> [LinkOverviewRow] {
        var remaining = ProjectLinks.openable(project.links)[...]
        return project.links.enumerated().compactMap { index, link in
            guard let first = remaining.first, first == link else { return nil }
            remaining = remaining.dropFirst()
            let lastOpened = visits.lastOpened(projectID: project.id, url: link.url)
            return LinkOverviewRow(projectID: project.id, index: index, link: link, lastOpened: lastOpened,
                                   due: LinkReminder.isDue(link, lastOpened: lastOpened, today: today, calendar: calendar))
        }
    }

    /// プロジェクトに確認が必要なリンクがあるか（ディレクトリの行の印）。
    public static func hasDue(_ project: ManagedProject, visits: LinkVisits, today: Date, calendar: Calendar) -> Bool {
        rows(of: project, visits: visits, today: today, calendar: calendar).contains(where: \.due)
    }

    /// 全プロジェクトの確認が必要な件数（固定の行の数字）。
    public static func dueCount(projects: [ManagedProject], visits: LinkVisits, today: Date, calendar: Calendar) -> Int {
        build(projects: projects, visits: visits, today: today, calendar: calendar).dueCount
    }
}
