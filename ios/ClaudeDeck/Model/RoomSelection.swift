/// 2 列（iPad）で右に開いているルームの扱い。
enum RoomSelection {
    /// 一覧から消えたルームは選んだままにせず、右を案内に戻す。
    static func kept(_ selection: String?, among roomIds: [String]) -> String? {
        guard let selection, roomIds.contains(selection) else { return nil }
        return selection
    }

    /// 積み上げ（compact）の画面の行き先。2 列と同じ選択から作るので、幅が変わっても開いている会話を保つ。
    static func path(for selection: String?) -> [String] {
        selection.map { [$0] } ?? []
    }

    /// 積み上げの画面で戻った・進んだ時の選択。
    static func selection(from path: [String]) -> String? {
        path.last
    }
}
