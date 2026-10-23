import DeckCore
import XCTest
@testable import ClaudeDeck

/// 終了になる選択肢（trust 確認の「No, exit」）は、Esc の終了と同じく確かめてから送る。
@MainActor
final class ExitConfirmationTests: XCTestCase {
    private func menu(id: String = "m1", exits: Bool?) -> RemoteMenu {
        RemoteMenu(menuId: id, context: [], question: "Is this a project you created or one you trust?",
                   options: [RemoteMenuOption(index: 0, number: nil, label: "No, exit", detail: [], checked: nil, isSubmit: false,
                                              selectable: true, exits: exits),
                             RemoteMenuOption(index: 1, number: nil, label: "Yes, I trust this folder", detail: [], checked: nil,
                                              isSubmit: false, selectable: true)],
                   cursor: 0, footer: "Enter to confirm · Esc to cancel", tabs: nil, isMultiSelect: false, isReview: false,
                   cancelExits: true)
    }

    func testMarkedChoiceAsksFirstWithItsName() throws {
        let marked = menu(exits: true)
        let confirmation = try XCTUnwrap(ExitConfirmation.needed(choosing: 0, in: marked))
        XCTAssertEqual(confirmation, ExitConfirmation(menuId: "m1", choice: 0, label: "No, exit"))
        XCTAssertEqual(confirmation.actionTitle, "終了する（No, exit）")
        XCTAssertTrue(confirmation.message.contains("「No, exit」"))
        XCTAssertNil(ExitConfirmation.needed(choosing: 1, in: marked), "終了にならない選択肢はそのまま送る")
        XCTAssertNil(ExitConfirmation.needed(choosing: 0, in: menu(exits: nil)), "印の無い古い mac では押す前には確かめない")
        XCTAssertEqual(ExitConfirmation.cancel("m1").actionTitle, "終了する（Esc）", "Esc の確認の文言は変えない")
    }

    #if DEBUG
    private func model(menu: RemoteMenu) -> (AppModel, RemoteRoom) {
        let room = RemoteRoom(id: "h:1", kind: .hosted, phase: .attention, name: "p", branch: nil, status: .waiting, line: "",
                              activityAt: nil, sessionId: "s", cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil,
                              menu: menu, unreadableMenu: nil, busy: false, send: RemoteSendState(mode: .input, disabledReason: nil))
        let pairing = RemotePairing(host: "192.168.1.5", port: 8767, localHostName: nil, fingerprint: String(repeating: "ab", count: 32),
                                    serverName: "Mac", deviceId: "d", deviceToken: "t", pairedAt: 0)
        return (AppModel(demo: RemoteState(rooms: [room], usage: nil, monitoring: true), pairing: pairing, transcripts: [:], open: nil), room)
    }

    func testOldMacRefusalAsksTheSameConfirmation() throws {
        let old = menu(exits: nil)
        let (model, room) = model(menu: old)
        model.menuAnswered(.failure("confirm_required", "x"), roomId: room.id, menu: old, choice: 0, confirmedExit: false)
        XCTAssertEqual(model.exitConfirmation(room, old), ExitConfirmation(menuId: "m1", choice: 0, label: "No, exit"))
        XCTAssertNil(model.notices[room.id], "断られた文ではなく確認を出す")
        XCTAssertNil(model.exitConfirmation(room, menu(id: "m2", exits: nil)), "別のメニューには出さない")

        model.dismissExitConfirmation(room.id)
        XCTAssertNil(model.exitConfirmation(room, old), "やめたら消す")

        model.menuAnswered(.failure("confirm_required", "x"), roomId: room.id, menu: old, choice: nil, confirmedExit: false)
        XCTAssertEqual(model.exitConfirmation(room, old), .cancel("m1"), "取り消しを断られた時も Esc の確認を出す")
        model.answerMenu(room, old, choice: nil, confirmExit: true)
        XCTAssertNil(model.exitConfirmation(room, old), "了承して送り直したら消す")
    }

    func testOtherResultsDoNotAsk() {
        let old = menu(exits: nil)
        let (model, room) = model(menu: old)
        model.menuAnswered(.failure("confirm_required", "x"), roomId: room.id, menu: old, choice: 0, confirmedExit: true)
        XCTAssertNil(model.exitConfirmation(room, old), "了承済みで断られたら確認を繰り返さない")
        model.menuAnswered(.failure("changed", "x"), roomId: room.id, menu: old, choice: 0, confirmedExit: false)
        model.menuAnswered(.success("confirmed"), roomId: room.id, menu: old, choice: 0, confirmedExit: false)
        model.menuAnswered(nil, roomId: room.id, menu: old, choice: 0, confirmedExit: false)
        XCTAssertNil(model.exitConfirmation(room, old))
    }

    func testConfirmationIsDroppedWhenTheMenuChanges() {
        let old = menu(exits: nil)
        let (model, room) = model(menu: old)
        model.menuAnswered(.failure("confirm_required", "x"), roomId: room.id, menu: old, choice: 0, confirmedExit: false)
        model.simulateReceived(RemoteState(rooms: [room], usage: nil, monitoring: true))
        XCTAssertNotNil(model.exitConfirmation(room, old), "同じメニューのままなら残す")

        var changed = room
        changed.menu = menu(id: "m2", exits: nil)
        model.simulateReceived(RemoteState(rooms: [changed], usage: nil, monitoring: true))
        XCTAssertNil(model.exitConfirmations[room.id], "メニューが替わったら確認も捨てる")
    }
    #endif
}
