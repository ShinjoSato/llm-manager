import Foundation

/// 使用量。statusline スクリプトが書いたファイルを読み直し、内容が変わった時だけ知らせる。
struct UsagePoller {
    let file: URL?
    private var usage: UsageSnapshot?
    private var read = false

    init(file: URL?) {
        self.file = file
    }

    /// 配る値。未生成・壊れていれば中身は nil（statusLine 未設定）。
    struct Change: Equatable {
        var usage: UsageSnapshot?
    }

    /// 読み直した結果。前回と同じ内容なら nil（配らない）。初回は未生成でも配る。
    mutating func poll() -> Change? {
        let next = UsageReader.read(file)
        if read && next == usage { return nil }
        read = true
        usage = next
        return Change(usage: next)
    }
}
