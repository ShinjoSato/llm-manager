import Foundation

/// Claude Code の使用量（移植元: monitor/src/usage.ts）。statusline スクリプトが書いた `data/claude-usage.json` を読むだけ。
public enum UsageReader {
    /// ファイルを読む。未生成・壊れていれば nil（statusLine 未設定でも動くように）。
    public static func read(_ url: URL?) -> UsageSnapshot? {
        guard let url, let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return parse(data)
    }

    /// 読んだ JSON をドメイン型に落とす。書き手が変わっても壊れないよう値を検分する。
    public static func parse(_ data: Data) -> UsageSnapshot? {
        guard let raw = JSONLoose.dict(JSONLoose.object(data)),
              let fetchedAt = JSONLoose.number(raw["fetchedAt"]) else { return nil }
        let fiveHour = window(raw["fiveHour"])
        let sevenDay = window(raw["sevenDay"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageSnapshot(fetchedAt: fetchedAt, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ v: Any?) -> UsageWindow? {
        guard let o = JSONLoose.dict(v), let used = JSONLoose.number(o["usedPercentage"]) else { return nil }
        return UsageWindow(usedPercentage: used, resetsAt: JSONLoose.number(o["resetsAt"]))
    }
}
