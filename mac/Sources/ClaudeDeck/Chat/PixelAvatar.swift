import SwiftUI
import MonitorKit

/// セッションの状態を monitor の 2D と同じドット絵キャラで出すアイコン。
struct PixelAvatar: View {
    let status: SessionStatus
    let size: CGFloat
    /// 状態名を隣の Text やバッジが読む場所では true にして、読み上げを重ねない。
    var hidesFromAccessibility = false
    /// 表示中の数。遅延スタックで行が移ると onDisappear が後から届くことがあり、真偽値だと止まったまま残る。
    @State private var appearances = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 全行が同じ境目でコマを切り替えるよう、時計の起点を固定する（.now だと行・再評価ごとにずれる）。
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        Group {
            // 画面に出ている動く絵だけ時計を回す（LazyVStack は画面外の行も保持するため）。
            if appearances > 0 && !reduceMotion && PixelCharacter.isAnimated(status) {
                TimelineView(.periodic(from: Self.epoch, by: PixelCharacter.tick)) { context in
                    PixelCanvas(status: status, tick: PixelCharacter.tickIndex(at: context.date))
                }
            } else {
                PixelCanvas(status: status, tick: 0)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28).fill(ChatTheme.color(for: status).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(ChatTheme.color(for: status).opacity(0.22)))
        .onAppear { appearances += 1 }
        .onDisappear { appearances = max(0, appearances - 1) }
        .accessibilityElement()
        .accessibilityLabel(ChatTheme.label(for: status))
        .accessibilityHidden(hidesFromAccessibility)
    }
}

private struct PixelCanvas: View {
    let status: SessionStatus
    let tick: Int

    var body: some View {
        Canvas { context, canvasSize in
            // 1 マスを整数ポイントにして補間なしで塗る（端数だとマスの幅が揃わずにじむ）。
            let cell = max(1, min(canvasSize.width / CGFloat(PixelCharacter.gridWidth),
                                  canvasSize.height / CGFloat(PixelCharacter.gridHeight)).rounded(.down))
            let originX = ((canvasSize.width - cell * CGFloat(PixelCharacter.gridWidth)) / 2).rounded(.down)
            let originY = ((canvasSize.height - cell * CGFloat(PixelCharacter.gridHeight)) / 2).rounded(.down)
            for run in PixelCharacter.runs(for: status, tick: tick) {
                let rect = CGRect(x: originX + CGFloat(run.x) * cell, y: originY + CGFloat(run.y) * cell,
                                  width: CGFloat(run.width) * cell, height: cell)
                context.fill(Path(rect), with: .color(Color(hex: run.color)), style: FillStyle(antialiased: false))
            }
        }
    }
}
