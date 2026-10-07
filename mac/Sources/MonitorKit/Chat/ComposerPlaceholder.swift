import Foundation

/// 入力欄のプレースホルダーの出し分け。下書き（確定分だけ）ではなく端末ビューの表示内容で判定し、日本語の変換中（marked text）も隠す。
public enum ComposerPlaceholder {
    /// 欄が空で、変換中でない時だけ出す。
    public static func isShown(shown: String, hasMarkedText: Bool) -> Bool {
        shown.isEmpty && !hasMarkedText
    }
}
