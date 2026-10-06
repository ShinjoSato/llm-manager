import Foundation

/// 職業 1 つ分の見本。`type` は代表のサブエージェント種別（判別できない従者は nil）。
public struct CharacterJobSample: Sendable, Equatable, Identifiable {
    public var type: String?
    public var job: StageJob
    public var id: String { type ?? "-" }
}

/// 持ち物 1 つ分の見本。`tool` を実行中にすると持つ。
public struct CharacterItemSample: Sendable, Equatable, Identifiable {
    public var tool: String
    public var label: String
    public var id: String { tool }
}

/// 設定画面のキャラクター一覧に並べる見本（UI 非依存）。実際の組み立てに渡すダミーのセッションもここで作る。
public enum CharacterGallery {
    /// 一覧に出す状態の順。要対応を稼働中の次に寄せ、取れていない状態は最後に置く。
    public static let statuses: [SessionStatus] = [.working, .permission, .waiting, .error, .idle, .stopped, .unknown]

    /// 見た目の違う職業ごとに 1 つ。種別名の順で、同じ名前と配色は先のものだけ残し、従者を最後に足す。
    public static let jobs: [CharacterJobSample] = {
        var seen: [StageJob] = []
        var out: [CharacterJobSample] = []
        for type in StageLogic.jobs.keys.sorted() {
            guard let job = StageLogic.jobs[type],
                  !seen.contains(where: { $0.label == job.label && $0.light == job.light && $0.dark == job.dark })
            else { continue }
            seen.append(job)
            out.append(CharacterJobSample(type: type, job: job))
        }
        out.append(CharacterJobSample(type: nil, job: StageLogic.unknownJob))
        return out
    }()

    /// ステージに一度に立てられる数ずつに分けた職業の組。
    public static func jobPages(size: Int = StageBlueprint.maxKids) -> [[CharacterJobSample]] {
        let step = max(1, size)
        return stride(from: 0, to: jobs.count, by: step).map { Array(jobs[$0..<min($0 + step, jobs.count)]) }
    }

    /// 持ち物の絵ごとに 1 つ。
    public static let items: [CharacterItemSample] = [
        CharacterItemSample(tool: "Bash", label: "端末"),
        CharacterItemSample(tool: "Read", label: "本"),
        CharacterItemSample(tool: "Edit", label: "槌"),
        CharacterItemSample(tool: "Skill", label: "巻物"),
        CharacterItemSample(tool: "WebFetch", label: "遠眼鏡"),
        CharacterItemSample(tool: "AskUserQuestion", label: "問い"),
        CharacterItemSample(tool: "Artifact", label: "画布"),
        CharacterItemSample(tool: "TodoWrite", label: "帳面"),
    ]

    /// 跳ねと脈のずれを毎回同じにするため、見本の id は固定する。
    public static let sessionId = "character-gallery"

    /// 見本のセッション。持ち物は稼働中の時だけ立つ（ステージと同じ判定に任せる）。
    public static func session(status: SessionStatus, jobs: [CharacterJobSample], tool: String?) -> SessionSnapshot {
        let agents = jobs.prefix(StageBlueprint.maxKids).enumerated().map { i, sample in
            AgentInfo(id: "kid-\(i)", type: sample.type, lastActivityAt: 0)
        }
        return SessionSnapshot(sessionId: sessionId, pid: 0, alive: status != .stopped, name: "見本", project: "見本",
                               cwd: "/", branch: nil, title: nil, lastPrompt: nil, status: status, statusSource: .hook,
                               statusDetail: nil, entrypoint: nil, version: nil, startedAt: 0, lastActivityAt: nil,
                               currentTool: tool, currentSkill: nil, currentAction: nil, tokens: nil, agents: agents,
                               canReceive: false, xcodeProject: nil)
    }

    public static func model(status: SessionStatus, jobs: [CharacterJobSample], tool: String?) -> StageSceneModel {
        StageSceneModel(session: session(status: status, jobs: jobs, tool: tool))
    }
}
