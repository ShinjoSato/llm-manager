import AppKit
import SceneKit
import XCTest
@testable import MonitorKit

/// ステージ（3D）の組み立て。期待値は three.js 版を同じ入力で動かした結果。
final class StageSceneTests: XCTestCase {
    private func session(_ status: SessionStatus, id: String = "00000000-aaaa-4bbb-8ccc-dddddddddddd",
                         tool: String? = nil, skill: String? = nil, agents: [AgentInfo] = []) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, pid: 1, alive: true, name: "s", project: "p", cwd: "/", branch: nil, title: nil,
                        lastPrompt: nil, status: status, statusSource: .hook, statusDetail: nil, entrypoint: nil,
                        version: nil, startedAt: 0, lastActivityAt: nil, currentTool: tool, currentSkill: skill,
                        currentAction: nil, tokens: nil, agents: agents, canReceive: true, xcodeProject: nil)
    }

    // MARK: - 寸法・配置

    func testBlueprintDimensions() {
        typealias B = StageBlueprint
        XCTAssertEqual(B.stepList.count, 5)
        XCTAssertEqual(B.topY, 2, accuracy: 1e-9)
        XCTAssertEqual(B.kidY, 1.6, accuracy: 1e-9)
        XCTAssertEqual(B.footprintX, 6, accuracy: 1e-9)
        XCTAssertEqual(B.footprintZ, 4.4, accuracy: 1e-9)
        XCTAssertEqual(B.kidZ, 0.8, accuracy: 1e-9)
        XCTAssertEqual(B.voxel, 0.108, accuracy: 1e-9)
        XCTAssertEqual(B.markBottom, 3.188, accuracy: 1e-9)
        XCTAssertEqual(B.headroom, 3.836, accuracy: 1e-9)
        XCTAssertEqual(B.spacingZ, 8.358014017833195, accuracy: 1e-9)
        XCTAssertEqual(B.stepList[0].width, 6, accuracy: 1e-9)
        XCTAssertEqual(B.stepList[4].width, 2.96, accuracy: 1e-9)
    }

    func testCameraFitMatchesMonitor() {
        let cases: [(Double, Double, Double)] = [
            (332.0 / 230, 6.80014858208081, 10.932487056581122),
            (1, 7.297254001007405, 12.045644197705055),
            (0.5, 11.53849742002868, 21.54296653493262),
        ]
        for (aspect, y, z) in cases {
            let fit = StageView(aspect: aspect).camera
            XCTAssertEqual(fit.position.x, 0)
            XCTAssertEqual(fit.position.y, y, accuracy: 1e-9)
            XCTAssertEqual(fit.position.z, z, accuracy: 1e-9)
            XCTAssertEqual(fit.target.y, 1.918, accuracy: 1e-9)
        }
    }

    func testGridLayoutStaggersRows() {
        let layout = StageBlueprint.gridLayout(count: 5, spacingX: 7, spacingZ: StageBlueprint.spacingZ, maxCols: 3)
        XCTAssertEqual(layout.spots.map(\.x), [-7, 0, 7, -3.5, 3.5])
        XCTAssertEqual(layout.spots[0].z, 4.179007008916598, accuracy: 1e-9)
        XCTAssertEqual(layout.spots[4].z, -4.179007008916598, accuracy: 1e-9)
        XCTAssertEqual(layout.spanX, 14)
        XCTAssertEqual(StageBlueprint.gridLayout(count: 0, spacingX: 7, spacingZ: 1, maxCols: 3).spots, [])
    }

    func testPhaseMatchesMonitorHash() {
        XCTAssertEqual(StageBlueprint.phase(of: "00000000-aaaa-4bbb-8ccc-dddddddddddd"), 0.5923123960383236, accuracy: 1e-12)
        XCTAssertEqual(StageBlueprint.phase(of: "abc"), 0.613210309529677, accuracy: 1e-12)
        XCTAssertEqual(StageBlueprint.phase(of: ""), 0.12479077302850783, accuracy: 1e-12)
        XCTAssertEqual(StageBlueprint.phase(of: "日本"), 0.5342210475355387, accuracy: 1e-12)
    }

    func testHopIsTwoFrames() {
        XCTAssertEqual(StageBlueprint.hop(0.2, period: 1.1, rise: 1), 0)
        XCTAssertEqual(StageBlueprint.hop(0.6, period: 1.1, rise: 1), 1)
        XCTAssertEqual(StageBlueprint.hop(-0.2, period: 1.1, rise: 1), 1)
        XCTAssertEqual(StageBlueprint.hop(.nan, period: 1.1, rise: 1), 0)
        XCTAssertEqual(StageBlueprint.hop(1, period: 0, rise: 1), 0)
    }

    func testPulseAndGlow() {
        XCTAssertEqual(StageBlueprint.pulse(.idle, at: 5), 0.32)
        XCTAssertEqual(StageBlueprint.pulse(.stopped, at: 5), 0.14)
        XCTAssertEqual(StageBlueprint.pulse(.unknown, at: 5), 0.32)
        XCTAssertEqual(StageBlueprint.pulse(.error, at: 0), 1.35)
        XCTAssertEqual(StageBlueprint.pulse(.permission, at: .pi / 2 / 3.4), 1.9, accuracy: 1e-9)
        XCTAssertEqual(StageBlueprint.glowColor(.working), 0x34d399)
        XCTAssertEqual(StageBlueprint.glowColor(.permission), 0xfbbf24)
        XCTAssertEqual(StageBlueprint.glowColor(.waiting), 0x60a5fa)
        XCTAssertEqual(StageBlueprint.glowColor(.error), 0xf87171)
        XCTAssertEqual(StageBlueprint.glowColor(.idle), 0x64748b)
        XCTAssertEqual(StageBlueprint.glowColor(.stopped), 0x3f4c5e)
    }

    // MARK: - 中身

    func testVoxelizeCentersAndStandsOnBottom() {
        let voxels = StageVoxels.voxelize(PixelSprite(["A.", ".B"]), palette: ["A": 1])
        XCTAssertEqual(voxels, [StageVoxel(x: -0.5, y: 1, color: 1)])
        XCTAssertEqual(StageVoxels.voxelize(PixelSprites.markBang, palette: ["A": 2]).map(\.y), [4, 3, 2, 0])
    }

    func testItemsFollowToolAndSkill() {
        XCTAssertEqual(StageItems.item(tool: "Bash", skill: nil)?.sprite, PixelSprites.itemTerminal)
        XCTAssertEqual(StageItems.item(tool: "Grep", skill: nil)?.sprite, PixelSprites.itemBook)
        XCTAssertEqual(StageItems.item(tool: "Bash", skill: "x:y")?.sprite, PixelSprites.itemScroll)
        XCTAssertEqual(StageItems.item(tool: "mcp__x", skill: nil)?.sprite, PixelSprites.itemNote)
        XCTAssertNil(StageItems.item(tool: "Agent", skill: nil))
        XCTAssertNil(StageItems.item(tool: "Task", skill: nil))
        XCTAssertNil(StageItems.item(tool: nil, skill: ""))
        XCTAssertEqual(StageItems.item(tool: "Skill", skill: nil)?.palette["P"], 0xf59e0b)
    }

    func testWorkingHasItemAndNoMark() {
        let model = StageSceneModel(session: session(.working, tool: "Bash"))
        XCTAssertNil(model.mark)
        XCTAssertEqual(model.item?.position.x, StageBlueprint.itemX)
        XCTAssertEqual(model.item?.glow?.color, 0x34d399)
        XCTAssertEqual(model.parent.position.y, 2 + 0.108 / 2, accuracy: 1e-9)
        XCTAssertTrue(model.parent.voxels.contains { $0.color == 0x34d399 })
        XCTAssertTrue(model.isAnimated)
        XCTAssertNil(StageSceneModel(session: session(.idle, tool: "Bash")).item)
    }

    func testMarksOnlyWhenCalling() {
        let permission = StageSceneModel(session: session(.permission))
        XCTAssertEqual(permission.mark?.voxels.map(\.color), Array(repeating: 0xfbbf24, count: 4))
        XCTAssertEqual(permission.mark?.glow?.color, 0xfbbf24)
        XCTAssertEqual(StageSceneModel(session: session(.waiting)).mark?.voxels.count, 6)
        XCTAssertEqual(StageSceneModel(session: session(.error)).mark?.voxels.first?.color, 0xf87171)
        for status in [SessionStatus.working, .idle, .stopped, .unknown] {
            XCTAssertNil(StageSceneModel(session: session(status)).mark)
            XCTAssertFalse(StageSceneModel(session: session(status)).beckons)
        }
        XCTAssertFalse(StageSceneModel(session: session(.idle)).isAnimated)
        XCTAssertFalse(StageSceneModel(session: session(.stopped)).isAnimated)
    }

    func testKidsAreCappedSortedAndColoredByJob() {
        let agents = ["e", "d", "c", "b", "a"].map { AgentInfo(id: $0, type: $0 == "b" ? "Explore" : nil, lastActivityAt: 0) }
        let model = StageSceneModel(session: session(.idle, agents: agents))
        XCTAssertEqual(model.kids.map(\.id), ["kid-b", "kid-c", "kid-d", "kid-e"])
        for (kid, x) in zip(model.kids, [-1.425, -0.475, 0.475, 1.425]) {
            XCTAssertEqual(kid.position.x, x, accuracy: 1e-9)
        }
        XCTAssertTrue(model.kids[0].voxels.contains { $0.color == 0xc084fc })
        XCTAssertTrue(model.kids[0].voxels.contains { $0.color == 0x7e22ce })
        XCTAssertEqual(model.kids[0].position.z, 0.8, accuracy: 1e-9)
        XCTAssertTrue(model.isAnimated)
    }

    // MARK: - 動き

    func testFrameHopsAndPulses() {
        let model = StageSceneModel(session: session(.working, tool: "Read"))
        let still = model.frame(at: 123, still: true)
        XCTAssertEqual(still.parentY, model.parent.position.y)
        XCTAssertEqual(still.itemY, model.item?.position.y)
        XCTAssertEqual(still.capGlow, 1.05 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(still.haloOpacity, 0.05 + 1.05 * 0.09, accuracy: 1e-9)

        // 跳ねは 2 コマ: 半周期ごとに地上と 1 マス上を行き来する。
        let lifts = stride(from: 0.0, to: 1.1, by: 0.05).map { model.frame(at: $0, still: false).parentY - model.parent.position.y }
        XCTAssertEqual(Set(lifts.map { ($0 * 1000).rounded() }), [0, 108])

        let idle = StageSceneModel(session: session(.idle))
        XCTAssertEqual(idle.frame(at: 0.7, still: false).parentY, idle.parent.position.y)
        XCTAssertEqual(idle.frame(at: 0.7, still: false).capGlow, 0.32 * 0.9, accuracy: 1e-9)

        let calling = StageSceneModel(session: session(.permission))
        let f = calling.frame(at: 0, still: true)
        XCTAssertEqual(f.haloOpacity, 0.12 + 1.3 * 0.16, accuracy: 1e-9)
        XCTAssertEqual(f.markGlowOpacity, 0.45 + 1.3 * 0.3, accuracy: 1e-9)
        XCTAssertEqual(f.markY, calling.mark?.position.y)
    }

    // MARK: - SceneKit

    func testRigRendersOffscreen() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal が使えない環境")
        let size = CGSize(width: 664, height: 460)
        let rig = StageSceneRig(aspect: Double(size.width / size.height))
        let background = NSColor(srgbRed: 0x0b / 255.0, green: 0x11 / 255.0, blue: 0x1d / 255.0, alpha: 1)
        let cases: [(String, SessionSnapshot)] = [
            ("working", session(.working, tool: "Bash")),
            ("agents", session(.working, tool: "Agent", agents: [
                AgentInfo(id: "a1", type: "Explore", lastActivityAt: 0),
                AgentInfo(id: "b2", type: "developer-plugin:code-reviewer", lastActivityAt: 0)])),
            ("permission", session(.permission)),
            ("waiting", session(.waiting)),
            ("error", session(.error)),
            ("idle", session(.idle)),
            ("stopped", session(.stopped)),
        ]
        let panelHex = ThemePalette.light.stagePanel
        let lightBackground = NSColor(srgbRed: CGFloat((panelHex >> 16) & 0xff) / 255, green: CGFloat((panelHex >> 8) & 0xff) / 255,
                                      blue: CGFloat(panelHex & 0xff) / 255, alpha: 1)
        let out = ProcessInfo.processInfo.environment["STAGE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for (backdrop, panel, suffix) in [(StageBackdrop.night, background, ""), (.light, lightBackground, "-light")] {
            rig.setBackdrop(backdrop)
            var corners: [CGFloat] = []
            for (name, s) in cases {
                rig.show(StageSceneModel(session: s))
                let image = try XCTUnwrap(rig.snapshot(size: size, time: 0, background: panel), name)
                let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init))
                // 段の正面（石の灰色）が画面の中ほどに描かれている。
                let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 292 / 460))
                XCTAssertGreaterThan(center.brightnessComponent, 0.5, name + suffix)
                corners.append(try XCTUnwrap(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh - 4)).brightnessComponent)
                if let out {
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: out.appendingPathComponent("\(name)\(suffix).png"))
                }
            }
            // 手前の地面はパネルの明るさに沿う（ライトで暗い床が浮かない）。
            for corner in corners {
                if backdrop == .light { XCTAssertGreaterThan(corner, 0.75) } else { XCTAssertLessThan(corner, 0.3) }
            }
        }
        rig.show(nil)
        XCTAssertFalse(rig.isAnimated)
    }
    /// 描画スレッドの更新と組み替えを並べて走らせても固まらない（描画はシーンの鍵を持って delegate を呼ぶ）。
    func testRigSurvivesConcurrentRenderAndRebuild() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal が使えない環境") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let rig = StageSceneRig(aspect: 1.4)
        let counter = FrameCounter(rig)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = rig.scene
        renderer.pointOfView = rig.cameraNode
        renderer.delegate = counter
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 96,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = device.makeTexture(descriptor: descriptor)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let models: [StageSceneModel?] = [
            StageSceneModel(session: session(.working, tool: "Bash")),
            StageSceneModel(session: session(.permission)),
            nil,
            StageSceneModel(session: session(.working, tool: "Agent", agents: [AgentInfo(id: "a1", type: "Explore", lastActivityAt: 0)])),
        ]
        let deadline = Date().addingTimeInterval(1.5)
        let rendered = expectation(description: "描画")
        let rebuilt = expectation(description: "組み替え")
        Thread {
            while Date() < deadline {
                autoreleasepool {
                    guard let buffer = queue.makeCommandBuffer() else { return }
                    renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: 0, y: 0, width: 128, height: 96),
                                    commandBuffer: buffer, passDescriptor: pass)
                    buffer.commit()
                    buffer.waitUntilCompleted()
                }
            }
            rendered.fulfill()
        }.start()
        Thread {
            var i = 0
            while Date() < deadline {
                rig.show(models[i % models.count])
                rig.setAspect(i % 2 == 0 ? 1.4 : 0.8)
                rig.setStill(i % 3 == 0)
                i += 1
            }
            rebuilt.fulfill()
        }.start()
        wait(for: [rendered, rebuilt], timeout: 20)
        XCTAssertGreaterThan(counter.frames, 0)
    }
}

/// 描画スレッドから呼ばれた回数を数えて rig に渡す。
private final class FrameCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let rig: StageSceneRig
    private let lock = NSLock()
    private var count = 0
    init(_ rig: StageSceneRig) { self.rig = rig }
    var frames: Int { lock.withLock { count } }
    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.withLock { count += 1 }
        rig.renderer(renderer, updateAtTime: time)
    }
}
