import DeckCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClaudeDeck

/// 送る前の写真の整え方（上限に収める・向き・メタデータ）。
final class ComposerImagePreparerTests: XCTestCase {
    private func image(width: Int, height: Int, type: UTType, noise: Bool = false, properties: [CFString: Any] = [:]) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if noise, let buffer = context.data {
            let bytes = buffer.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            var seed: UInt64 = 42
            for i in 0..<(context.bytesPerRow * height) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        } else {
            context.setFillColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func size(_ data: Data) -> (Int, Int, [CFString: Any]) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return ((p[kCGImagePropertyPixelWidth] as! NSNumber).intValue, (p[kCGImagePropertyPixelHeight] as! NSNumber).intValue, p)
    }

    func testLargeScreenshotStaysPNGAndShrinks() throws {
        let prepared = try XCTUnwrap(ComposerImagePreparer.prepare(image(width: 3000, height: 1500, type: .png)))
        XCTAssertEqual(prepared.payload.mediaType, "image/png", "収まるスクリーンショットは PNG のまま")
        let (w, h, _) = size(prepared.payload.data)
        XCTAssertEqual(max(w, h), RemoteImageLimits.preferredLongEdge)
        XCTAssertEqual(w / h, 2)
        XCTAssertNil(RemoteImageLimits.problem([prepared.payload]), "mac の検査を通る形")
        XCTAssertNotNil(UIImage(data: prepared.thumbnail))
    }

    func testBusyImageBecomesJPEGWithinTheBudget() throws {
        let budget = 400 * 1024
        let prepared = try XCTUnwrap(ComposerImagePreparer.prepare(image(width: 2400, height: 1800, type: .png, noise: true), budget: budget))
        XCTAssertEqual(prepared.payload.mediaType, "image/jpeg", "収まらない PNG は JPEG にする")
        XCTAssertLessThanOrEqual(prepared.payload.data.count, budget)
        XCTAssertNil(RemoteImageLimits.problem([prepared.payload]))
    }

    func testOrientationIsAppliedAndLocationIsDropped() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 139.76, kCGImagePropertyGPSLongitudeRef: "E"]
        let photo = image(width: 40, height: 20, type: .jpeg,
                          properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps])
        XCTAssertNotNil(size(photo).2[kCGImagePropertyGPSDictionary], "元の写真には位置情報がある")
        let prepared = try XCTUnwrap(ComposerImagePreparer.prepare(photo))
        XCTAssertEqual(prepared.payload.mediaType, "image/jpeg")
        let (w, h, properties) = size(prepared.payload.data)
        XCTAssertEqual([w, h], [20, 40], "向きを反映して起こす")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "位置情報は送らない")
        XCTAssertNil(RemoteImageLimits.problem([prepared.payload]))
    }

    func testHEICBecomesJPEG() throws {
        let output = NSMutableData()
        guard CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) != nil else {
            throw XCTSkip("この環境では HEIC を書けない")
        }
        let prepared = try XCTUnwrap(ComposerImagePreparer.prepare(image(width: 64, height: 48, type: .heic)))
        XCTAssertEqual(prepared.payload.mediaType, "image/jpeg")
        XCTAssertNil(RemoteImageLimits.problem([prepared.payload]))
    }

    func testUnreadableDataIsRejected() {
        XCTAssertNil(ComposerImagePreparer.prepare(Data("not an image".utf8)))
        XCTAssertNil(ComposerImagePreparer.prepare(Data()))
    }
}

/// 入力欄の画像の並べ方と送り方。
@MainActor
final class AppModelImagesTests: XCTestCase {
    #if DEBUG
    private func model(send: RemoteSendState) -> (AppModel, RemoteRoom) {
        let room = RemoteRoom(id: send.mode == .relay ? "e:1" : "h:1", kind: send.mode == .relay ? .external : .hosted, phase: .idle,
                              name: "p", branch: nil, status: .idle, line: "", activityAt: nil, sessionId: "s", cwd: "/", ended: nil,
                              session: nil, permissions: [], terminalPermission: nil, menu: nil, unreadableMenu: nil, busy: false, send: send)
        let pairing = RemotePairing(host: "192.168.1.5", port: 8767, localHostName: nil, fingerprint: String(repeating: "ab", count: 32),
                                    serverName: "Mac", deviceId: "d", deviceToken: "t", pairedAt: 0)
        return (AppModel(demo: RemoteState(rooms: [room], usage: nil, monitoring: true), pairing: pairing, transcripts: [:], open: nil), room)
    }

    private func png() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6))
        return renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("時間内に揃いませんでした") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testOnlyHostedRoomsThatAcceptImagesCanAttach() {
        XCTAssertTrue(model(send: RemoteSendState(mode: .input, disabledReason: nil, acceptsImages: true)).0
            .canAttachImages(model(send: RemoteSendState(mode: .input, disabledReason: nil, acceptsImages: true)).1))
        let (m, old) = model(send: RemoteSendState(mode: .input, disabledReason: nil))
        XCTAssertFalse(m.canAttachImages(old), "画像を知らない mac には付けない（黙って落とされるため）")
        let (r, relay) = model(send: RemoteSendState(mode: .relay, disabledReason: nil, acceptsImages: false))
        XCTAssertFalse(r.canAttachImages(relay), "伝言は文字だけ")
    }

    func testAttachUpToTheLimitAndRemove() async throws {
        let (model, room) = model(send: RemoteSendState(mode: .input, disabledReason: nil, acceptsImages: true))
        let data = png()
        model.attachImages(Array(repeating: data, count: RemoteImageLimits.maxCount + 2), to: room.id) { $0 }
        XCTAssertEqual(model.notices[room.id]?.isError, true, "上限を超えた分は理由を出す")
        XCTAssertEqual(model.remainingImageSlots(room.id), 0, "整えている間の分も数える")
        XCTAssertFalse(model.hasSomethingToSend(room.id), "整え終わるまで送らない")
        try await waitUntil { model.images(room.id).count == RemoteImageLimits.maxCount }
        XCTAssertNil(model.preparingImages[room.id])
        XCTAssertTrue(model.hasSomethingToSend(room.id), "本文が空でも画像だけで送れる")
        XCTAssertTrue(model.images(room.id).allSatisfy { $0.payload.mediaType == "image/png" })

        model.removeImage(model.images(room.id)[0], from: room.id)
        XCTAssertEqual(model.images(room.id).count, RemoteImageLimits.maxCount - 1)
        XCTAssertEqual(model.remainingImageSlots(room.id), 1)
    }

    func testUnreadablePhotoIsReported() async throws {
        let (model, room) = model(send: RemoteSendState(mode: .input, disabledReason: nil, acceptsImages: true))
        model.attachImages([Data("x".utf8)], to: room.id) { $0 }
        try await waitUntil { model.preparingImages[room.id] == nil }
        XCTAssertTrue(model.images(room.id).isEmpty)
        XCTAssertEqual(model.notices[room.id]?.isError, true)
    }

    func testFailedSendKeepsTheImages() async throws {
        let (model, room) = model(send: RemoteSendState(mode: .input, disabledReason: nil, acceptsImages: true))
        model.attachImages([png()], to: room.id) { $0 }
        try await waitUntil { model.images(room.id).count == 1 }
        model.send(room)
        XCTAssertEqual(model.images(room.id).count, 1, "送れなければ画像は残す")
        XCTAssertEqual(model.notices[room.id]?.isError, true)
    }

    func testRelayRefusesImagesWithoutSending() async throws {
        let (model, room) = model(send: RemoteSendState(mode: .relay, disabledReason: nil, acceptsImages: false))
        model.attachImages([png()], to: room.id) { $0 }
        try await waitUntil { model.images(room.id).count == 1 }
        model.drafts[room.id] = "伝言"
        model.send(room)
        XCTAssertNil(model.relayNotes["s"], "画像付きの伝言は送らない")
        XCTAssertEqual(model.notices[room.id]?.isError, true)
    }
    #endif
}
