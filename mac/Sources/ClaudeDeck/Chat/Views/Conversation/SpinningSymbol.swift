import SwiftUI

/// 読み込み中を表す、一定の速さで回り続ける SF Symbol（視差効果を減らす設定では止めたまま）。
struct SpinningSymbol: View {
    let systemName: String
    /// 1 回転にかける秒数。
    var period: TimeInterval = 1.1
    /// 表示中の数。遅延スタックで行が移ると onDisappear が後から届くことがあり、真偽値だと止まったまま残る。
    @State private var appearances = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            // 角度を時刻から決めるので、外れれば時計ごと止まりアニメーションの状態が残らない。
            if appearances > 0 && !reduceMotion {
                TimelineView(.animation) { context in
                    Image(systemName: systemName)
                        .rotationEffect(.degrees(Self.degrees(at: context.date, period: period)))
                }
            } else {
                Image(systemName: systemName)
            }
        }
        .onAppear { appearances += 1 }
        .onDisappear { appearances = max(0, appearances - 1) }
    }

    /// 時刻 date での角度（0 以上 360 未満）。
    static func degrees(at date: Date, period: TimeInterval) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return (phase < 0 ? phase + 1 : phase) * 360
    }
}
