import Foundation

/// 監視（SessionHub / TranscriptStore）から `MonitorStore` へ流れる変化。
public enum MonitorEvent: Sendable, Equatable {
    case sessions([SessionSnapshot])
    case feed(FeedItem)
    case feedBatch([FeedItem])
    /// statusLine 未設定なら nil。
    case usage(UsageSnapshot?)
    case permissions([PendingPermission])
    case transcript(TranscriptEvent)
}
