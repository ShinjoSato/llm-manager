/// 開いている画面（会話かプロジェクトの詳細）。積み上げでは道のり、2 列では右の列の中身になる。
enum DeckRoute: Hashable {
    case room(String)
    case project(String)
}

/// 左の一覧の見方（mac の「ルーム」「ディレクトリ」と横断のリンク一覧）。
enum SidebarMode: String, CaseIterable, Identifiable {
    case rooms, directory, links

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rooms: return "ルーム"
        case .directory: return "ディレクトリ"
        case .links: return "リンク"
        }
    }

    var symbol: String {
        switch self {
        case .rooms: return "bubble.left.and.bubble.right"
        case .directory: return "folder"
        case .links: return "link"
        }
    }

    /// プロジェクトの一覧（`GET /v1/projects`）を使う見方か。
    var usesProjects: Bool { self != .rooms }
}

/// プロジェクトの詳細のタブ（mac のディレクトリの詳細のうち、iPhone で見られるもの）。
enum ProjectDetailTab: String, CaseIterable, Identifiable {
    case links, threads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .links: return "リンク"
        case .threads: return "スレッド"
        }
    }
}

/// 開いている画面の扱い。2 列と積み上げで同じ道のりを共有し、幅が変わっても同じ画面を開いたままにする。
enum RoomSelection {
    /// 一覧から消えたルーム・登録から消えたプロジェクトから先は閉じる（2 列で右を案内に戻すため）。
    /// `projectIds` が nil（まだ読んでいない・読めない）の間はプロジェクトを消えたとみなさない。
    static func kept(_ route: [DeckRoute], roomIds: [String], projectIds: [String]?) -> [DeckRoute] {
        let rooms = Set(roomIds)
        let projects = projectIds.map(Set.init)
        var result: [DeckRoute] = []
        for step in route {
            switch step {
            case .room(let id): guard rooms.contains(id) else { return result }
            case .project(let id): if let projects, !projects.contains(id) { return result }
            }
            result.append(step)
        }
        return result
    }

    /// 一覧の行を押した時の道のり（その行の画面だけを開く）。
    static func open(_ step: DeckRoute) -> [DeckRoute] { [step] }

    /// 一覧の行を選んで見せるか（2 列で右に開いている最初の画面がその行）。
    static func isSelected(_ step: DeckRoute, in route: [DeckRoute]) -> Bool {
        route.first == step
    }
}
