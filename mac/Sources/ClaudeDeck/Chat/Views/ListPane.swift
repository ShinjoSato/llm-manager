import AppKit
import SwiftUI
import MonitorKit

/// 左の一覧の幅の状態。描く幅とステージの判定に使う幅だけを観測させ、ウィンドウや中央の幅は読むだけにする。
@MainActor
@Observable
final class ListPaneLayout {
    /// 一覧を描く幅（ドラッグ中はつかんでいる幅、狭いウィンドウでは中央の最小幅を保てるよう縮めた幅）。
    private(set) var displayWidth: Double
    /// ステージパネルの自動で畳む判定に使う幅（ドラッグ中はつかんだ時の幅のまま）。
    private(set) var stageWidth: Double

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saved: Double
    @ObservationIgnored private var windowWidth: Double?
    @ObservationIgnored private var drag: ListPaneDrag?
    /// ドラッグの開始時にだけ読む。
    @ObservationIgnored var centerWidth: Double = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: ListPaneWidth.defaultsKey) as? Double ?? ListPaneWidth.standard
        saved = ListPaneWidth.clamped(stored)
        displayWidth = saved
        stageWidth = saved
    }

    var isDragging: Bool { drag != nil }

    func windowWidthChanged(_ width: Double) {
        windowWidth = width
        refresh()
    }

    func dragChanged(translation: Double) {
        if drag == nil { drag = ListPaneDrag(startWidth: displayWidth, centerWidth: centerWidth) }
        drag?.move(translation: translation)
        refresh()
    }

    func dragEnded() {
        guard let drag else { return }
        self.drag = nil
        save(drag.width)
    }

    func resetToStandard() {
        guard drag == nil else { return }
        save(ListPaneWidth.reset(from: displayWidth, centerWidth: centerWidth))
    }

    private func save(_ width: Double) {
        saved = ListPaneWidth.clamped(width)
        defaults.set(saved, forKey: ListPaneWidth.defaultsKey)
        refresh()
    }

    /// 値が変わった時だけ書き、ウィンドウの伸縮のたびに見ている画面を描き直させない。
    private func refresh() {
        let display = drag?.width ?? ListPaneWidth.fitted(saved, windowWidth: windowWidth)
        let stage = drag?.widthForStage ?? display
        if display != displayWidth { displayWidth = display }
        if stage != stageWidth { stageWidth = stage }
    }
}

/// 一覧の列。幅の変化でここだけを描き直す。
struct ListPaneColumn<Content: View>: View {
    let layout: ListPaneLayout
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: layout.displayWidth)
            .background(ListPaneWindowSync(layout: layout,
                                           minimumWidth: ListPaneWidth.minimumWindowWidth(listWidth: layout.displayWidth)))
    }
}

/// 一覧と中央の境界。つかんで一覧の幅を変え、ダブルクリックで既定に戻す。
struct ListPaneDivider: View {
    let layout: ListPaneLayout
    @State private var hovering = false
    @State private var cursorPushed = false

    /// 線は 1pt のまま、つかめる幅を中央側にだけ広げる（一覧のスクロールバーに重ねない）。
    private static let grabWidth: CGFloat = 8

    var body: some View {
        Rectangle()
            .fill(ChatTheme.border)
            .frame(width: 1)
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: Self.grabWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        updateCursor()
                    }
                    .gesture(dragGesture)
                    .onTapGesture(count: 2) { layout.resetToStandard() }
                    .help("ドラッグで一覧の幅を変える（ダブルクリックで元の幅）")
            }
            .onDisappear {
                if cursorPushed { NSCursor.pop() }
                cursorPushed = false
            }
            .accessibilityElement()
            .accessibilityLabel("一覧の幅")
            .accessibilityValue("\(Int(layout.displayWidth)) ポイント")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                layout.dragChanged(translation: value.translation.width)
                updateCursor()
            }
            .onEnded { _ in
                layout.dragEnded()
                updateCursor()
            }
    }

    /// つかんでいる間はカーソルが境界から外れても左右の矢印のままにする。
    private func updateCursor() {
        let wants = hovering || layout.isDragging
        guard wants != cursorPushed else { return }
        if wants { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        cursorPushed = wants
    }
}

/// ウィンドウの幅を一覧の状態へ渡し、一覧の幅に応じて中央が最小幅を保てるウィンドウの最小幅を掛ける。
struct ListPaneWindowSync: NSViewRepresentable {
    let layout: ListPaneLayout
    let minimumWidth: Double

    func makeNSView(context: Context) -> ListPaneWindowView {
        let view = ListPaneWindowView()
        view.layout = layout
        view.minimumWidth = minimumWidth
        return view
    }

    func updateNSView(_ view: ListPaneWindowView, context: Context) {
        view.layout = layout
        view.minimumWidth = minimumWidth
    }
}

final class ListPaneWindowView: WindowResizeView {
    weak var layout: ListPaneLayout?
    var minimumWidth: Double = 0 {
        didSet { applyMinimum() }
    }

    override func didAttach(to window: NSWindow) {
        applyMinimum()
    }

    override func windowDidResize(_ window: NSWindow) {
        let width = window.contentLayoutRect.width
        // 画面の更新中に観測される値を書き換えないよう、次の周回で渡す。
        DispatchQueue.main.async { [weak self] in self?.layout?.windowWidthChanged(width) }
    }

    private func applyMinimum() {
        guard minimumWidth > 0, let window, window.contentMinSize.width != minimumWidth else { return }
        window.contentMinSize = NSSize(width: minimumWidth, height: window.contentMinSize.height)
    }
}
