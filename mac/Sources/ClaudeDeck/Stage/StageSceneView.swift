import AppKit
import SceneKit
import SwiftUI
import MonitorKit

/// ステージの 3D（SceneKit）。中身は `StageSceneModel`、組み立てと動きは `StageSceneRig` が持つ。
struct StageSceneView: NSViewRepresentable {
    let model: StageSceneModel
    var backdrop: StageBackdrop = .night

    func makeNSView(context: Context) -> StageSCNView {
        StageSCNView(frame: .zero)
    }

    func updateNSView(_ view: StageSCNView, context: Context) {
        view.show(model, backdrop: backdrop)
    }

    static func dismantleNSView(_ view: StageSCNView, coordinator: ()) {
        view.stop()
    }
}

final class StageSCNView: SCNView {
    /// 2 コマの跳ねと脈打つ光には 30fps で足りる。上げても見た目は変わらず GPU を食うだけ。
    private static let framesPerSecond = 30

    private let rig = StageSceneRig(aspect: 332.0 / 230.0)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = rig.scene
        pointOfView = rig.cameraNode
        delegate = rig
        backgroundColor = .clear
        wantsLayer = true
        layer?.isOpaque = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = Self.framesPerSecond
        allowsCameraControl = false
        isPlaying = false
        rendersContinuously = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("ステージ")
        setAccessibilityIdentifier("stage-scene")
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayback() }
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ model: StageSceneModel, backdrop: StageBackdrop) {
        rig.setBackdrop(backdrop)
        rig.show(model)
        refreshPlayback()
        needsDisplay = true
    }

    func stop() {
        isPlaying = false
        rendersContinuously = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        rig.setAspect(Double(bounds.width / bounds.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.removeAll { center, token in
            guard center === NotificationCenter.default else { return false }
            center.removeObserver(token)
            return true
        }
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append((center, center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPlayback() }
                }))
            }
        }
        refreshPlayback()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshPlayback()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshPlayback()
    }

    /// 見えていて動くものがある時だけ毎フレーム描く。動きを減らす設定では静止の姿勢で止める。
    private func refreshPlayback() {
        rig.setStill(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let playing = visible && !isHiddenOrHasHiddenAncestor && rig.isAnimated
        if rendersContinuously != playing { rendersContinuously = playing }
        if isPlaying != playing { isPlaying = playing }
        if !playing { needsDisplay = true }
    }
}

/// ウィンドウの幅を知らせる（狭い時にパネルを自動で畳むため）。
struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat?

    func makeNSView(context: Context) -> WidthReportingView {
        let view = WidthReportingView()
        view.onChange = { width = $0 }
        return view
    }

    func updateNSView(_ view: WidthReportingView, context: Context) {
        view.onChange = { width = $0 }
    }
}

final class WidthReportingView: WindowResizeView {
    var onChange: ((CGFloat) -> Void)?

    override func windowDidResize(_ window: NSWindow) {
        let width = window.frame.width
        DispatchQueue.main.async { [weak self] in self?.onChange?(width) }
    }
}
