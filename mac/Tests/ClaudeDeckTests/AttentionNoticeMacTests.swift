import CloudKit
import XCTest
@testable import MonitorKit

final class AttentionNoticeSourceTests: XCTestCase {
    private func candidate(status: SessionStatus, ended: Bool = false, hookTool: String? = nil, detail: String? = nil,
                           tools: [String] = []) -> AttentionCandidate? {
        AttentionNoticeSource.candidate(roomId: "h:1", sessionId: "s1", name: "mirio", status: status, ended: ended,
                                        hookToolName: hookTool, statusDetail: detail, permissionToolNames: tools)
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

    func testToolNameComesFromChannelsThenHookThenPermissionMessage() {
        XCTAssertEqual(candidate(status: .permission, hookTool: "Bash", detail: "Bash: x", tools: ["Edit"])?.toolName, "Edit")
        XCTAssertEqual(candidate(status: .permission, hookTool: "Bash", detail: "Bash: git push --force")?.toolName, "Bash")
        XCTAssertEqual(candidate(status: .permission, detail: "Claude needs your permission to use Write.")?.toolName, "Write")
        // フックの tool_name が無い時、補足の頭の語はツール名と見分けられないので使わない。
        XCTAssertNil(candidate(status: .permission, detail: "Bash: git push --force")?.toolName)
        XCTAssertNil(candidate(status: .permission, detail: "Error: rate limited")?.toolName)
        XCTAssertNil(candidate(status: .permission, detail: "foo.env")?.toolName)
        XCTAssertNil(candidate(status: .permission, hookTool: "rm -rf /")?.toolName)
        XCTAssertNil(candidate(status: .permission, detail: "削除してよいですか")?.toolName)
        // 権限待ち以外ではツール名を付けない。
        XCTAssertNil(candidate(status: .waiting, hookTool: "Bash", detail: "Claude needs your permission to use Bash")?.toolName)
        XCTAssertNil(candidate(status: .error, detail: "Error: x")?.toolName)
    }

    func testRoomNameIsTheFolderOrTheRegisteredProject() {
        XCTAssertEqual(AttentionNoticeSource.roomName(hostedProjectName: "mirio", project: "repo", cwd: "/a/repo"), "mirio")
        XCTAssertEqual(AttentionNoticeSource.roomName(hostedProjectName: nil, project: "repo", cwd: "/a/repo"), "repo")
        XCTAssertEqual(AttentionNoticeSource.roomName(hostedProjectName: nil, project: "", cwd: "/a/folder/"), "folder")
        XCTAssertEqual(AttentionNoticeSource.roomName(hostedProjectName: nil, project: nil, cwd: "/"), "")
    }

    @MainActor
    func testExternalRoomNameIgnoresTheSessionName() {
        // セッション名（会話から付くことがある）ではなくフォルダ名を載せる。
        let snapshot = SessionSnapshot(sessionId: "s1", pid: 1, alive: true, name: "fix secret-token leak", project: "sandora",
                                       cwd: "/Users/x/sandora", branch: nil, title: nil, lastPrompt: nil, status: .waiting,
                                       statusSource: .hook, statusDetail: nil, entrypoint: nil, version: nil, startedAt: 0,
                                       lastActivityAt: nil, currentTool: nil, currentSkill: nil, currentAction: nil, tokens: nil,
                                       agents: [], canReceive: false, xcodeProject: nil)
        let name = AttentionNoticeSource.roomName(hostedProjectName: nil, project: snapshot.project, cwd: snapshot.cwd)
        XCTAssertEqual(name, "sandora")
        let c = AttentionNoticeSource.candidate(roomId: "e:s1", sessionId: "s1", name: name, status: snapshot.status, ended: false,
                                                hookToolName: nil, statusDetail: nil, permissionToolNames: [])!
        var planner = AttentionNoticePlanner(config: .init(settle: 0, cooldown: 0), macName: "Mac")
        guard case .save(let notice) = planner.update([c], now: 0).first else { return XCTFail() }
        for case .string(let value) in AttentionNoticeSchema.fields(of: notice).values {
            XCTAssertFalse(value.contains("secret"), value)
        }
    }

    func testSummaryCarriesNoDetailText() {
        let c = candidate(status: .permission, hookTool: "Bash", detail: "Bash: cat ~/.ssh/id_ed25519")!
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
        let container = "iCloud.example.claude-deck"
        XCTAssertTrue(CloudKitAvailability.matches(services: ["CloudKit"], containers: [container], container: container))
        XCTAssertFalse(CloudKitAvailability.matches(services: ["CloudDocuments"], containers: [container], container: container))
        XCTAssertFalse(CloudKitAvailability.matches(services: ["CloudKit"], containers: ["iCloud.other"], container: container))
        XCTAssertFalse(CloudKitAvailability.matches(services: nil, containers: nil, container: container))
        XCTAssertFalse(CloudKitAvailability.matches(services: ["CloudKit"], containers: [""], container: ""))
    }

    /// 試験の実行ファイルは署名にエンタイトルメントを持たないので、CKContainer を作らずに無効と判断する。
    func testUnsignedProcessIsUnavailable() {
        XCTAssertEqual(CloudKitAvailability.current(container: "iCloud.example.claude-deck"),
                       .unavailable(CloudKitAvailability.missingEntitlementReason))
    }

    /// コンテナが設定されていない起動（swift run・試験・Local.xcconfig 無しの .app）は、その理由で無効にする。
    func testMissingContainerIsUnavailable() {
        XCTAssertEqual(CloudKitAvailability.current(container: nil), .unavailable(CloudKitAvailability.missingContainerReason))
        XCTAssertNil(CloudKitAvailability.bundleContainer())
        XCTAssertEqual(CloudKitAvailability.current(), .unavailable(CloudKitAvailability.missingContainerReason))
    }

    func testErrorMessages() {
        XCTAssertEqual(CloudKitNoticeError.from(code: .notAuthenticated).message, "この Mac で iCloud にサインインしていません")
        XCTAssertEqual(CloudKitNoticeError.from(code: .networkUnavailable).message, "ネットワークにつながっていません")
        XCTAssertTrue(CloudKitNoticeError.from(code: .badContainer).message.contains("コンテナ"))
        XCTAssertEqual(CloudKitNoticeError.from(CKError(.requestRateLimited)).message, "iCloud が混み合っています")
    }
}
