import AppKit
import SceneKit

/// `StageSceneModel` を SceneKit のノードに起こして動かす。描画面（SCNView / SCNRenderer）はこれを読むだけ。
/// ノードの組み替えは呼び出し側のスレッド、動きは描画スレッド（`renderer(_:updateAtTime:)`）から触る。
public final class StageSceneRig: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    public let scene = SCNScene()
    public let cameraNode = SCNNode()

    /// 描画スレッドと分け合う状態（動かすノードの参照）。
    private struct Moving {
        var model: StageSceneModel?
        var still = false
        var parent: SCNNode?
        var mark: SCNNode?
        var item: SCNNode?
        var kids: [SCNNode] = []
        var cap: SCNMaterial?
        var halo: [SCNMaterial] = []
        var markGlow: SCNMaterial?
    }

    // 描画スレッドはシーンの鍵を持って delegate を呼びうる。この鍵の中で SceneKit を触ると順序が逆転しうるので、
    // 参照の読み書きだけに使い、シーングラフの付け外しは鍵の外で SCNTransaction.lock の中で行う。
    private let lock = NSLock()
    private var moving = Moving()
    // 以下は呼び出し側のスレッドだけが触る。
    private var view: StageView
    private var ziggurat: SCNNode?
    private let world = SCNNode()
    private let ground = SCNNode()
    private let grid = SCNNode()

    // three.js の光は物理単位（拡散は 1/π 倍）なので、出典の強さ（0.85 / 1.7 / 0.5）を SceneKit の 1000 = 1 に直す。
    static let ambientIntensity = CGFloat(0.85 / Double.pi * 1000)
    static let keyIntensity = CGFloat(1.7 / Double.pi * 1000)
    static let rimIntensity = CGFloat(0.5 / Double.pi * 1000)

    /// three.js（react-three-fiber の既定）の ACESFilmicToneMapping を変数 c に掛ける。これが無いと光る段が原色のまま飛ぶ。
    static let aces = """
    c *= 1.0 / 0.6;
    c = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383),
                 float3(0.04823, 0.01566, 0.83777)) * c;
    c = (c * (c + 0.0245786) - 0.000090537) / (c * (0.983729 * c + 0.4329510) + 0.238081);
    c = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276),
                 float3(-0.07367, -0.00605, 1.07602)) * c;
    """

    static let toneMapping = """
    #pragma body
    float alpha = _output.color.a;
    float3 c = alpha > 0.0 ? _output.color.rgb / alpha : float3(0.0);
    \(aces)
    _output.color.rgb = saturate(c) * alpha;
    """

    /// 光の板。three.js は canvas の絵（16 進の値をそのまま線形として読む）を tone map し、濃さ × opacity を掛けて足す。
    /// 濃さは出典 glowTexture の放射グラデーション（中心 d0 → 4 割で 50 → 縁で 0）。絵を介すと色空間の変換で縁が濃くなるので式で描く。
    static let glowShading = """
    #pragma arguments
    float3 glowColor;
    float glowOpacity;
    #pragma body
    float r = length(_surface.diffuseTexcoord - float2(0.5)) * 2.0;
    float density = r < 0.4 ? mix(208.0, 80.0, r / 0.4) / 255.0 : (r < 1.0 ? mix(80.0, 0.0, (r - 0.4) / 0.6) / 255.0 : 0.0);
    float3 c = glowColor;
    \(aces)
    c = saturate(c);
    // three.js は sRGB に直してから足す。暗い地の上では「sRGB で足した量」を線形に戻して足すのとほぼ同じになる。
    float3 encoded = select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, 12.92 * c, c <= float3(0.0031308));
    float3 k = encoded * density * glowOpacity;
    _output.color = float4(select(pow((k + 0.055) / 1.055, float3(2.4)), k / 12.92, k <= float3(0.04045)), 1.0);
    """

    public init(aspect: Double) {
        view = StageView(aspect: aspect)
        super.init()
        buildWorld()
        applyView(lines: Self.gridNodes(size: view.groundWidth, divisions: view.gridDivisions))
    }

    // MARK: - 外から

    /// 動きを減らす設定。止めた時は静止の姿勢で描く。
    public func setStill(_ value: Bool) {
        lock.withLock { moving.still = value }
    }

    public func setAspect(_ aspect: Double) {
        let next = StageView(aspect: aspect)
        guard next != view else { return }
        view = next
        let lines = Self.gridNodes(size: next.groundWidth, divisions: next.gridDivisions)
        Self.withSceneLock { applyView(lines: lines) }
    }

    /// 中身が変わった時だけ組み直す。nil なら何も立てない。
    public func show(_ next: StageSceneModel?) {
        guard next != lock.withLock({ moving.model }) else { return }
        var built = Moving(model: next)
        let node = next.map { buildZiggurat($0, into: &built) }
        let old = ziggurat
        ziggurat = node
        lock.withLock {
            built.still = moving.still
            moving = built
        }
        Self.withSceneLock {
            old?.removeFromParentNode()
            if let node { world.addChildNode(node) }
        }
        applyFrame(at: 0)
    }

    public var isAnimated: Bool {
        lock.withLock { (moving.model?.isAnimated ?? false) && !moving.still }
    }

    /// 時刻 `time`（秒）の姿勢にする。
    public func apply(time: TimeInterval) {
        applyFrame(at: time)
    }

    public func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        apply(time: time)
    }

    /// オフスクリーンで 1 枚描く（見た目の確認・テスト用）。
    public func snapshot(size: CGSize, time: TimeInterval, background: NSColor? = nil) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        apply(time: time)
        let renderer = SCNRenderer(device: device, options: nil)
        let previous = scene.background.contents
        Self.withSceneLock { scene.background.contents = background }
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: time, with: size, antialiasingMode: .multisampling4X)
        Self.withSceneLock { scene.background.contents = previous }
        return image
    }

    /// シーングラフの変更を描画と同じ鍵（SceneKit の transaction lock）の中で行う。
    static func withSceneLock<T>(_ body: () throws -> T) rethrows -> T {
        SCNTransaction.lock()
        defer { SCNTransaction.unlock() }
        return try body()
    }

    // MARK: - 組み立て

    private func buildWorld() {
        let camera = SCNCamera()
        camera.fieldOfView = StageBlueprint.fov
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 400
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = Self.ambientIntensity
        ambient.light?.color = NSColor.white
        scene.rootNode.addChildNode(ambient)
        scene.rootNode.addChildNode(directional(at: SCNVector3(8, 14, 10), intensity: Self.keyIntensity, color: .white))
        scene.rootNode.addChildNode(directional(at: SCNVector3(-9, 4, -7), intensity: Self.rimIntensity,
                                                color: Self.color(0x7dd3fc)))

        ground.eulerAngles.x = -.pi / 2
        ground.geometry = SCNPlane(width: 1, height: 1)
        let groundMaterial = Self.lambert(StageBlueprint.groundColor)
        // 出典の地面は MeshStandardMaterial で、奥からの青い光（rim）の照り返しが乗る。lambert には無いので一定量を足す。
        groundMaterial.emission.contents = Self.linearColor(0.0085, 0.0080, 0.0105)
        ground.geometry?.firstMaterial = groundMaterial
        world.addChildNode(ground)
        grid.position.y = 0.005
        world.addChildNode(grid)
        scene.rootNode.addChildNode(world)
        scene.fogColor = Self.color(StageBlueprint.fogColor)
        scene.fogDensityExponent = 1
    }

    private func directional(at position: SCNVector3, intensity: CGFloat, color: NSColor) -> SCNNode {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = .directional
        node.light?.intensity = intensity
        node.light?.color = color
        node.position = position
        node.look(at: SCNVector3(0, 0, 0))
        return node
    }

    private func applyView(lines: [SCNNode]) {
        let fit = view.camera
        cameraNode.position = SCNVector3(fit.position.x, fit.position.y, fit.position.z)
        cameraNode.look(at: SCNVector3(fit.target.x, fit.target.y, fit.target.z))
        let width = CGFloat(view.groundWidth)
        (ground.geometry as? SCNPlane)?.width = width
        (ground.geometry as? SCNPlane)?.height = width
        grid.childNodes.forEach { $0.removeFromParentNode() }
        lines.forEach(grid.addChildNode)
        scene.fogStartDistance = CGFloat(view.fogStart)
        scene.fogEndDistance = CGFloat(view.fogEnd)
    }

    private func buildZiggurat(_ model: StageSceneModel, into parts: inout Moving) -> SCNNode {
        typealias B = StageBlueprint
        let root = SCNNode()

        let halo = Self.halo(color: model.glow)
        halo.position.y = 0.02
        root.addChildNode(halo)
        parts.halo = Self.haloMaterials(halo)

        let cap = Self.lambert(B.capColor)
        cap.emission.contents = Self.color(model.glow)
        parts.cap = cap
        let stone = Self.lambert(B.stoneColor)
        let shade = Self.lambert(B.shadeColor)
        for step in B.stepList {
            let body = SCNNode(geometry: SCNBox(width: step.width, height: step.top - step.base - B.cap,
                                                length: step.depth, chamferRadius: 0))
            body.geometry?.firstMaterial = step.level % 2 == 1 ? stone : shade
            body.position.y = (step.base + step.top - B.cap) / 2
            root.addChildNode(body)
            // 縁取り板は一回り大きくする。同じ大きさで重ねると段の境目が消える。
            let plate = SCNNode(geometry: SCNBox(width: step.width + B.nosing * 2, height: B.cap,
                                                 length: step.depth + B.nosing * 2, chamferRadius: 0))
            plate.geometry?.firstMaterial = cap
            plate.position.y = step.top - B.cap / 2
            root.addChildNode(plate)
        }

        let parent = Self.figureNode(model.parent)
        root.addChildNode(parent)
        parts.parent = parent

        if let mark = model.mark {
            let node = Self.figureNode(mark)
            parts.markGlow = node.childNode(withName: "glow", recursively: false)?.geometry?.firstMaterial
            root.addChildNode(node)
            parts.mark = node
        }
        if let item = model.item {
            let node = Self.figureNode(item)
            Self.setGlowOpacity(node.childNode(withName: "glow", recursively: false)?.geometry?.firstMaterial, 0.9)
            root.addChildNode(node)
            parts.item = node
        }
        parts.kids = model.kids.map { kid in
            let node = Self.figureNode(kid)
            root.addChildNode(node)
            return node
        }
        return root
    }

    private func applyFrame(at time: TimeInterval) {
        let m = lock.withLock { moving }
        guard let model = m.model else { return }
        let frame = model.frame(at: time, still: m.still)
        m.parent?.position.y = CGFloat(frame.parentY)
        if let y = frame.itemY { m.item?.position.y = CGFloat(y) }
        if let y = frame.markY { m.mark?.position.y = CGFloat(y) }
        for (node, y) in zip(m.kids, frame.kidYs) { node.position.y = CGFloat(y) }
        m.cap?.emission.intensity = CGFloat(frame.capGlow)
        for material in m.halo { material.setValue(NSNumber(value: Float(frame.haloOpacity)), forKey: "haloOpacity") }
        Self.setGlowOpacity(m.markGlow, frame.markGlowOpacity)
    }

    // MARK: - 部品

    /// 置き場のノード。中に絵（1 マス = scale の立方体）と、あれば光の板を持つ。
    static func figureNode(_ figure: StageFigure) -> SCNNode {
        let node = SCNNode()
        node.name = figure.id
        node.position = SCNVector3(figure.position.x, figure.position.y, figure.position.z)
        let body = voxelNode(figure.voxels, depth: StageBlueprint.figureDepth)
        body.scale = SCNVector3(figure.scale, figure.scale, figure.scale)
        if let glow = figure.glow {
            node.addChildNode(glowNode(glow))
        }
        node.addChildNode(body)
        return node
    }

    /// 立方体の集まりを色ごとの 1 形状にまとめる（描画の呼び出しを減らす）。
    static func voxelNode(_ voxels: [StageVoxel], depth: Double) -> SCNNode {
        let container = SCNNode()
        var boxes: [UInt32: SCNBox] = [:]
        for voxel in voxels {
            let box: SCNBox
            if let cached = boxes[voxel.color] {
                box = cached
            } else {
                box = SCNBox(width: 1, height: 1, length: depth, chamferRadius: 0)
                box.firstMaterial = lambert(voxel.color)
                boxes[voxel.color] = box
            }
            let cell = SCNNode(geometry: box)
            cell.position = SCNVector3(voxel.x, voxel.y, 0)
            container.addChildNode(cell)
        }
        return container.flattenedClone()
    }

    /// カメラを向く光の板。足し算で重ねる（引き算だと影に見える）。
    static func glowNode(_ glow: StageGlow) -> SCNNode {
        let plane = SCNPlane(width: glow.size, height: glow.size)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        material.shaderModifiers = [.fragment: glowShading]
        let c = rgb(glow.color)
        material.setValue(NSValue(scnVector3: SCNVector3(c[0], c[1], c[2])), forKey: "glowColor")
        setGlowOpacity(material, 1)
        plane.firstMaterial = material
        let node = SCNNode(geometry: plane)
        node.name = "glow"
        node.position.y = CGFloat(glow.offsetY)
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 10
        return node
    }

    static func setGlowOpacity(_ material: SCNMaterial?, _ value: Double) {
        material?.setValue(NSNumber(value: Float(value)), forKey: "glowOpacity")
    }

    /// 足元の影と光の輪（出典 Ziggurat.tsx の shadow / halo）。three.js は半透明を sRGB のまま重ねるので、
    /// 線形で重ねる SceneKit で同じ板を使うと明るく出る。地面の上で sRGB の重ね結果になるよう、
    /// 下を残す割合を掛ける板と足りない分を足す板の 2 枚に分ける（下のグリッドの線も同じ割合で透ける）。
    static func haloShading(adding: Bool) -> String {
        """
        #pragma arguments
        float3 haloColor;
        float haloOpacity;
        #pragma body
        float r = length(_surface.diffuseTexcoord - float2(0.5)) * 2.0;
        float3 c = haloColor;
        \(aces)
        c = saturate(c);
        float3 halo = select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, 12.92 * c, c <= float3(0.0031308));
        float3 ground = float3(\(groundUnderHalo.r), \(groundUnderHalo.g), \(groundUnderHalo.b));
        float remain = (r < \(StageBlueprint.shadowRadius / StageBlueprint.groundRadius) ? 0.65 : 1.0) * (1.0 - haloOpacity);
        float3 mixed = ground * remain + halo * haloOpacity;
        float3 wanted = select(pow((mixed + 0.055) / 1.055, float3(2.4)), mixed / 12.92, mixed <= float3(0.04045));
        float3 groundLinear = select(pow((ground + 0.055) / 1.055, float3(2.4)), ground / 12.92, ground <= float3(0.04045));
        _output.color = float4(\(adding ? "max(wanted - groundLinear * remain, float3(0.0))" : "float3(remain)"), 1.0);
        """
    }

    /// 光の輪の下に見える地面の色（sRGB）。比べ撮りで測った地面の色に合わせる。
    static let groundUnderHalo = (r: 0x0a / 255.0, g: 0x14 / 255.0, b: 0x26 / 255.0)

    /// 掛ける板と足す板を持つノード。どちらも深度を書かず、地面とグリッドの後にこの順で描く。
    static func halo(color hex: UInt32) -> SCNNode {
        let node = SCNNode()
        node.eulerAngles.x = -.pi / 2
        let c = rgb(hex).map(decodeSRGB)
        for (order, adding) in [(1, false), (2, true)] {
            let radius = StageBlueprint.groundRadius
            let plane = SCNPlane(width: radius * 2, height: radius * 2)
            plane.cornerRadius = radius
            plane.cornerSegmentCount = 7
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.white
            material.blendMode = adding ? .add : .multiply
            material.writesToDepthBuffer = false
            material.shaderModifiers = [.fragment: haloShading(adding: adding)]
            material.setValue(NSValue(scnVector3: SCNVector3(c[0], c[1], c[2])), forKey: "haloColor")
            material.setValue(NSNumber(value: Float(0.1)), forKey: "haloOpacity")
            plane.firstMaterial = material
            let pass = SCNNode(geometry: plane)
            pass.renderingOrder = order
            node.addChildNode(pass)
        }
        return node
    }

    static func haloMaterials(_ node: SCNNode) -> [SCNMaterial] {
        node.childNodes.compactMap { $0.geometry?.firstMaterial }
    }

    static func decodeSRGB(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// three.js の GridHelper と同じ線（中心の 2 本だけ明るい色）。色ごとに 1 形状にする。
    /// 1px の線は tone map すると地面に沈む（出典では地面より明るく見える）ので、色をそのまま出す。
    static func gridNodes(size: Double, divisions: Int) -> [SCNNode] {
        let half = size / 2
        let step = size / Double(divisions)
        let center = divisions / 2
        var plain: [SCNVector3] = []
        var middle: [SCNVector3] = []
        for i in 0...divisions {
            let k = -half + Double(i) * step
            let lines = [SCNVector3(-half, 0, k), SCNVector3(half, 0, k), SCNVector3(k, 0, -half), SCNVector3(k, 0, half)]
            if i == center { middle += lines } else { plain += lines }
        }
        return [(plain, StageBlueprint.gridColor), (middle, StageBlueprint.gridCenterColor)].compactMap { vertices, hex in
            guard !vertices.isEmpty else { return nil }
            let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color(hex)
            geometry.firstMaterial = material
            return SCNNode(geometry: geometry)
        }
    }

    static func lambert(_ hex: UInt32) -> SCNMaterial {
        let material = toneMapped(SCNMaterial())
        material.lightingModel = .lambert
        material.diffuse.contents = color(hex)
        return material
    }

    static func toneMapped(_ material: SCNMaterial) -> SCNMaterial {
        material.shaderModifiers = [.fragment: toneMapping]
        return material
    }

    static func linearColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
        return NSColor(cgColor: CGColor(colorSpace: space, components: [r, g, b, 1])!)!
    }

    static func rgb(_ hex: UInt32) -> [Float] {
        [Float((hex >> 16) & 0xff) / 255, Float((hex >> 8) & 0xff) / 255, Float(hex & 0xff) / 255]
    }

    static func color(_ hex: UInt32) -> NSColor {
        let c = rgb(hex)
        return NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
    }
}
