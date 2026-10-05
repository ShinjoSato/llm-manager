import CloudKit
import XCTest
@testable import MonitorKit

final class AttentionNoticeSourceTests: XCTestCase {
    private func candidate(status: SessionStatus, ended: Bool = false, detail: String? = nil,
                           tools: [String] = []) -> AttentionCandidate? {
        AttentionNoticeSource.candidate(roomId: "h:1", sessionId: "s1", name: "mirio", status: status, ended: ended,
                                        statusDetail: detail, permissionToolNames: tools)
    }

    func testOnlyAttentionStatusesBecomeCandidates() {
        XCTAssertEqual(candidate(status: .permission)?.kind, .permission)
        XCTAssertEqual(candidate(status: .waiting)?.kind, .waiting)
        XCTAssertEqual(candidate(status: .error)?.kind, .error)
        XCTAssertNil(candidate(status: .working))
        XCTAssertNil(candidate(status: .idle))
        XCTAssertNil(candidate(status: .stopped))
        XCTAssertNil(candidate(status: .unknown))
        // 終わったセッションは待っていない。
        XCTAssertNil(candidate(status: .permission, ended: true))
    }

    func testToolNameComesFromChannelsThenFromTheDetailHead() {
        XCTAssertEqual(candidate(status: .permission, detail: "Bash: x", tools: ["Edit"])?.toolName, "Edit")
        XCTAssertEqual(candidate(status: .permission, detail: "Bash: git push --force")?.toolName, "Bash")
        XCTAssertNil(candidate(status: .permission, detail: "削除してよいですか")?.toolName)
        // 入力待ちの補足（通知文）は使わない。
        XCTAssertNil(candidate(status: .waiting, detail: "Claude is waiting for your input")?.toolName)
    }

    func testSummaryCarriesNoDetailText() {
        let c = candidate(status: .permission, detail: "Bash: cat ~/.ssh/id_ed25519")!
        var planner = AttentionNoticePlanner(config: .init(settle: 0, cooldown: 0), macName: "Mac")
        guard case .save(let notice) = planner.update([c], now: 0).first else { return XCTFail() }
        XCTAssertEqual(notice.summary, "権限の確認を待っています（Bash）")
        XCTAssertFalse(notice.body.contains("ssh"))
    }
}

final class CloudKitNoticeStoreTests: XCTestCase {
    func testRecordHasOnlyTheSchemaFields() {
        let notice = AttentionNotice(recordName: "attn-h_1-5", roomId: "h:1", sessionId: "s1", roomName: "mirio", kind: .waiting,
                                     summary: "入力を待っています", title: "mirio", body: "入力を待っています", since: 5,
                                     roomIds: ["h:1", "e:2"], macName: "Mac")
        let record = CloudKitNoticeStore.record(for: notice)
        XCTAssertEqual(record.recordType, AttentionNoticeSchema.recordType)
        XCTAssertEqual(record.recordID.recordName, "attn-h_1-5")
        XCTAssertEqual(Set(record.allKeys()), AttentionNoticeSchema.allFields)
        XCTAssertEqual(record[AttentionNoticeSchema.Field.roomId] as? String, "h:1")
        XCTAssertEqual(record[AttentionNoticeSchema.Field.since] as? Int64, 5)
        XCTAssertEqual(record[AttentionNoticeSchema.Field.roomIds] as? [String], ["h:1", "e:2"])
        XCTAssertEqual(record[AttentionNoticeSchema.Field.kind] as? String, "waiting")
    }

    func testEntitlementMatching() {
        XCTAssertTrue(CloudKitAvailability.matches(services: ["CloudKit"], containers: [AttentionNoticeSchema.containerIdentifier]))
        XCTAssertFalse(CloudKitAvailability.matches(services: ["CloudDocuments"], containers: [AttentionNoticeSchema.containerIdentifier]))
        XCTAssertFalse(CloudKitAvailability.matches(services: ["CloudKit"], containers: ["iCloud.other"]))
        XCTAssertFalse(CloudKitAvailability.matches(services: nil, containers: nil))
    }

    /// 試験の実行ファイルは署名にエンタイトルメントを持たないので、CKContainer を作らずに無効と判断する。
    func testUnsignedProcessIsUnavailable() {
        XCTAssertEqual(CloudKitAvailability.current(), .unavailable(CloudKitAvailability.missingEntitlementReason))
    }

    func testErrorMessages() {
        XCTAssertEqual(CloudKitNoticeError.from(code: .notAuthenticated).message, "この Mac で iCloud にサインインしていません")
        XCTAssertEqual(CloudKitNoticeError.from(code: .networkUnavailable).message, "ネットワークにつながっていません")
        XCTAssertTrue(CloudKitNoticeError.from(code: .badContainer).message.contains("コンテナ"))
        XCTAssertEqual(CloudKitNoticeError.from(CKError(.requestRateLimited)).message, "iCloud が混み合っています")
    }
}
