import XCTest
@testable import MonitorKit

/// 設定画面のキャラクター一覧に並べる見本。
final class CharacterGalleryTests: XCTestCase {
    func testStatusesListEveryStateOnce() {
        let all: Set<SessionStatus> = [.working, .waiting, .permission, .idle, .error, .stopped, .unknown]
        XCTAssertEqual(Set(CharacterGallery.statuses), all)
        XCTAssertEqual(CharacterGallery.statuses.count, all.count)
    }

    func testJobsCoverEveryLookWithoutDuplicates() {
        let samples = CharacterGallery.jobs
        func key(_ job: StageJob) -> String { "\(job.label)|\(job.light)|\(job.dark)" }
        XCTAssertEqual(Set(samples.map { key($0.job) }).count, samples.count)
        XCTAssertEqual(Set(samples.map(\.id)).count, samples.count)
        for job in StageLogic.jobs.values {
            XCTAssertTrue(samples.contains { key($0.job) == key(job) }, job.label)
        }
        for sample in samples {
            XCTAssertEqual(StageLogic.job(for: sample.type), sample.job)
        }
        XCTAssertNil(samples.last?.type)
        XCTAssertEqual(samples.last?.job, StageLogic.unknownJob)
    }

    func testJobPagesSplitByStageCapacity() {
        let pages = CharacterGallery.jobPages()
        XCTAssertEqual(pages.flatMap { $0 }, CharacterGallery.jobs)
        XCTAssertTrue(pages.allSatisfy { !$0.isEmpty && $0.count <= StageBlueprint.maxKids })
        XCTAssertEqual(CharacterGallery.jobPages(size: 0).count, CharacterGallery.jobs.count)
    }

    func testItemsCoverEveryItemSprite() {
        let shown = CharacterGallery.items.compactMap { StageItems.item(tool: $0.tool, skill: nil) }
        XCTAssertEqual(shown.count, CharacterGallery.items.count)
        for (i, item) in shown.enumerated() {
            XCTAssertFalse(shown[..<i].contains(item), CharacterGallery.items[i].tool)
        }
        for item in StageItems.items.values {
            XCTAssertTrue(shown.contains(item))
        }
    }

    func testModelUsesStageAssemblyForParentKidsAndItem() {
        let page = Array(CharacterGallery.jobs.prefix(StageBlueprint.maxKids))
        let working = CharacterGallery.model(status: .working, jobs: page, tool: "Edit")
        XCTAssertEqual(working, StageSceneModel(session: CharacterGallery.session(status: .working, jobs: page, tool: "Edit")))
        XCTAssertNotNil(working.item)
        XCTAssertNil(working.mark)
        XCTAssertEqual(working.kids.count, page.count)
        for (kid, sample) in zip(working.kids, page) {
            let colors = Set(kid.voxels.map(\.color))
            XCTAssertTrue(colors.contains(sample.job.light), sample.job.label)
            XCTAssertTrue(colors.contains(sample.job.dark), sample.job.label)
        }

        let permission = CharacterGallery.model(status: .permission, jobs: [], tool: "Edit")
        XCTAssertNil(permission.item)
        XCTAssertNotNil(permission.mark)
        XCTAssertTrue(permission.kids.isEmpty)

        let tooMany = CharacterGallery.model(status: .idle, jobs: CharacterGallery.jobs, tool: nil)
        XCTAssertEqual(tooMany.kids.count, StageBlueprint.maxKids)
    }
}
