import DeckCore
import SwiftUI

/// セッションの状態を mac アプリと同じドット絵キャラで出すアイコン（状態名は隣の文字が読むので読み上げない）。
struct PixelAvatar: View {
    let status: SessionStatus
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 全行が同じ境目でコマを切り替えるよう、時計の起点を固定する。
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        Group {
            if !reduceMotion && PixelCharacter.isAnimated(status) {
                TimelineView(.periodic(from: Self.epoch, by: PixelCharacter.tick)) { context in
                    PixelCanvas(status: status, tick: PixelCharacter.tickIndex(at: context.date))
                }
            } else {
                PixelCanvas(status: status, tick: 0)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28).fill(DeckTheme.color(for: status).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(DeckTheme.color(for: status).opacity(0.22)))
        .accessibilityHidden(true)
    }
}

struct PixelCanvas: View {
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

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        let color = DeckTheme.color(for: status)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(DeckTheme.label(for: status))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ExternalTag: View {
    var body: some View {
        Text("外部")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DeckTheme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).stroke(DeckTheme.inputBorder))
            .accessibilityLabel("アプリの外で動いているセッション")
    }
}
