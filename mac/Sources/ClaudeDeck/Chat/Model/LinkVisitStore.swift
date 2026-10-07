import Foundation
import Observation
import MonitorKit

/// リンクを最後に開いた時刻の持ち手。起動時に読み、記録のたびに `link-visits.json` に書く（書けなくても落とさない）。
@MainActor
@Observable
final class LinkVisitStore {
    static let shared = LinkVisitStore(file: LinkVisitsFile(url: LinkVisitsFile.defaultURL()))

    private(set) var visits: LinkVisits
    /// 直近の書き込みの失敗（画面に出すだけ）。
    private(set) var saveError: String?
    /// 期日の判定に使う「今」。開いたままでも日付が変われば印が替わるよう、ときどき進める。
    private(set) var now = Date()
    @ObservationIgnored private let file: LinkVisitsFile
    @ObservationIgnored private var clock: Task<Void, Never>?

    init(file: LinkVisitsFile) {
        self.file = file
        visits = file.load()
    }

    /// 設定から消えたリンクの分を片付け、日付の時計を回す。設定が読めない・空の間は消さない（外で消されたファイルや別の設定で全部失わないため）。
    func start() {
        let settings = SettingsStore.shared
        if settings.problem == nil, !settings.projects.isEmpty { prune(keeping: settings.projects) }
        clock?.cancel()
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                self?.now = Date()
            }
        }
    }

    func lastOpened(projectID: UUID, link: ProjectLink) -> Date? {
        visits.lastOpened(projectID: projectID, url: link.url)
    }

    func isDue(projectID: UUID, link: ProjectLink) -> Bool {
        LinkReminder.isDue(link, lastOpened: lastOpened(projectID: projectID, link: link), today: now, calendar: .autoupdatingCurrent)
    }

    func record(projectID: UUID, link: ProjectLink) {
        let date = Date()
        visits.record(projectID: projectID, url: link.url, at: date)
        now = date
        save()
    }

    /// URL を編集した行の記録を新しい URL へ写す。
    func carry(projectID: UUID, from oldURL: String, to newURL: String) {
        let before = visits
        visits.carry(projectID: projectID, from: oldURL, to: newURL)
        if visits != before { save() }
    }

    func prune(keeping projects: [ManagedProject]) {
        let pruned = visits.pruned(keeping: LinkVisits.keys(in: projects))
        guard pruned != visits else { return }
        visits = pruned
        save()
    }

    private func save() {
        do {
            try file.save(visits)
            saveError = nil
        } catch {
            saveError = "link-visits.json に書けませんでした（最終確認日は次の起動まで残りません）"
        }
    }
}
