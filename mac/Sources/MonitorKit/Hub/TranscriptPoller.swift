import Foundation

/// 実況層。ログ（jsonl）の末尾差分とサブエージェントの様子を State に映し、フィードは配らずに返す。
struct TranscriptPoller {
    /// サブエージェントのログがこの時間内に更新されていれば、そのエージェントは動いているとみなす。
    static let agentWindow: Double = 3 * 60_000
    /// サブエージェント数の走査は syscall が多いので実況ポーリングより粗くする。
    static let agentScanInterval: Double = 2_000

    private var locator: TranscriptLocator
    private var agentTypes: [String: String] = [:]
    /// これより前のログ行はフィードに積まない（起動前の履歴を「新着」として数えないため）。
    let startedAt: Double

    struct Outcome {
        /// 配信するフィード（ログの順）。
        var feed: [FeedLine] = []
        var changed = false
        /// 新しいログ行を読んだ（預かった権限の確認が端末側で答えられていないかを見る合図）。
        var readLines = false
        /// 後から見つかったログ。メタ情報の遡り読みを SessionHub が actor の外で行う。
        var metaRequest: String?
    }

    init(home: ClaudeHome, startedAt: Double) {
        locator = TranscriptLocator(home: home)
        self.startedAt = startedAt
    }

    /// 新しいセッションにログを結び付ける。遡り読みは呼び出し側（loadMeta）が行うので、ここでは頼んだ印だけ付ける。
    mutating func attach(_ state: SessionState) {
        state.transcriptPath = locator.resolve(sessionId: state.raw.sessionId, cwd: state.raw.cwd)
        if let path = state.transcriptPath { state.reader = TranscriptReader(path: path) }
        state.metaRequestedFor = state.transcriptPath
    }

    /// 捨てるセッションのキャッシュを片付ける。
    mutating func forget(_ state: SessionState) {
        guard let path = state.transcriptPath else { return }
        let dir = ClaudeHome.subagentDirectory(forTranscript: path)
        for key in agentTypes.keys where key.hasPrefix(dir) { agentTypes[key] = nil }
    }

    /// 末尾読みで既に新しい値を拾っていればそちらを残す。
    @discardableResult
    func absorbMeta(_ meta: (title: String?, lastPrompt: String?), into state: SessionState) -> Bool {
        let before = (state.title, state.lastPrompt)
        state.title = state.title ?? meta.title
        state.lastPrompt = state.lastPrompt ?? meta.lastPrompt
        return before != (state.title, state.lastPrompt)
    }

    /// 追記分を State に映す。ログがまだ無ければ何もしない。
    mutating func poll(_ state: SessionState, now: Double) -> Outcome {
        var outcome = Outcome()
        if state.reader == nil {
            // 起動直後はログがまだ無いことがあるので都度あきらめずに探す。
            guard let path = locator.resolve(sessionId: state.raw.sessionId, cwd: state.raw.cwd) else { return outcome }
            state.transcriptPath = path
            state.reader = TranscriptReader(path: path)
        }
        guard let reader = state.reader else { return outcome }
        if let path = state.transcriptPath, state.metaRequestedFor != path {
            state.metaRequestedFor = path
            outcome.metaRequest = path
        }

        // 初回は末尾を遡って読むので、起動前に書かれた行を新着としてフィードに積まない。
        let initial = !reader.primed
        let events = reader.read()
        if !events.isEmpty {
            outcome.changed = true
            outcome.readLines = true
        }
        let quietFlags = initial ? initialQuietFlags(events, knownAtStart: state.knownAtStart) : nil

        for (index, ev) in events.enumerated() {
            let quiet = quietFlags?[index] ?? false
            func push(_ kind: FeedKind, _ text: String, tool: String? = nil) {
                if !quiet { outcome.feed.append(FeedLine(kind: kind, text: text, tool: tool)) }
            }
            if let branch = ev.branch { state.branch = branch }
            if let title = ev.title, title != state.title {
                state.title = title
                push(.message, "作業内容: \(title)")
            }
            if let prompt = ev.lastPrompt, prompt != state.lastPrompt {
                state.lastPrompt = prompt
                push(.prompt, HubText.truncate(prompt, 160))
            }
            if let at = ev.at { state.lastActivityAt = max(state.lastActivityAt ?? 0, at) }
            if let usage = ev.usage { state.tokens = usage }

            // thinking だけの assistant 行では判定を変えない（応答が終わったとは限らない）。
            if ev.type == "assistant" {
                if ev.tools?.isEmpty == false { state.turnState = .busy } else if ev.text != nil { state.turnState = .settled }
            } else if ev.type == "user" {
                state.turnState = .busy // プロンプト送信か tool_result。どちらも次はモデルの番
            }

            if let tools = ev.tools, !tools.isEmpty {
                state.currentTool = tools.last
                // 配下のツールには skill が無い。nil で塗り潰さず、新しいスキルが来た時だけ差し替える。
                if let skill = ev.toolDetail?.skill { state.currentSkill = skill }
                state.currentAction = ev.toolDetail?.description
                for tool in tools { push(.tool, tool, tool: tool) }
                // フックより新しい行を読んだ時だけ「待ち」を解く。古い行で権限待ちを消さない。
                if (ev.at ?? .infinity) > state.hookAt { state.clearHookWait() }
            } else if ev.type == "user" {
                // tool_result が返った = ツールは終わっている
                state.currentTool = nil
                state.currentAction = nil
                // スキルは配下のツールが動く間ずっと続く。次の指示が来るまで保持する。
                if ev.userKind == .prompt { state.currentSkill = nil }
            } else if ev.type == "assistant", let text = ev.text {
                // スキルは途中で一言述べても続いている。解除は次のユーザー指示だけに任せる。
                state.currentTool = nil
                state.currentAction = nil
                push(.message, HubText.truncate(text, 160))
            }
        }

        if now - state.agentsCheckedAt >= Self.agentScanInterval {
            state.agentsCheckedAt = now
            let (agents, newest) = scanAgents(state, now: now)
            if newest > 0 { state.lastAgentActivityAt = max(state.lastAgentActivityAt ?? 0, newest) }
            func key(_ list: [AgentInfo]) -> String { list.map { "\($0.id):\($0.type ?? "")" }.sorted().joined(separator: ",") }
            if key(agents) != key(state.agents) { outcome.changed = true }
            state.agents = agents
        }
        return outcome
    }

    /// 初回読みの各行を起動前の分とみなすか。時刻の無い行は近くの時刻のある行に倣う（--resume で書き直された古いメタ情報を新着にしないため）。
    private func initialQuietFlags(_ events: [ParsedEvent], knownAtStart: Bool) -> [Bool] {
        var flags = [Bool](repeating: knownAtStart, count: events.count)
        var previous: Double?
        for (index, ev) in events.enumerated() {
            if let at = ev.at { previous = at }
            if let reference = previous { flags[index] = reference < startedAt }
        }
        // 先頭側の時刻の無い行は、後に続く時刻のある行が起動前ならそれより前に書かれている。
        if let firstTimed = events.firstIndex(where: { $0.at != nil }), let at = events[firstTimed].at, at < startedAt {
            for index in 0..<firstTimed { flags[index] = true }
        }
        return flags
    }

    /// 稼働中のサブエージェント一覧と、サブエージェント側の最終更新時刻を返す。
    private mutating func scanAgents(_ state: SessionState, now: Double) -> ([AgentInfo], Double) {
        guard let path = state.transcriptPath else { return ([], 0) }
        let dir = ClaudeHome.subagentDirectory(forTranscript: path)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return ([], 0) }
        var agents: [AgentInfo] = []
        var newest: Double = 0
        for file in files where file.hasSuffix(".jsonl") {
            let full = "\(dir)/\(file)"
            var st = stat()
            guard stat(full, &st) == 0 else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec) / 1_000_000
            newest = max(newest, mtime)
            if now - mtime >= Self.agentWindow { continue }
            var id = String(file.dropLast(".jsonl".count))
            if id.hasPrefix("agent-") { id = String(id.dropFirst("agent-".count)) }
            agents.append(AgentInfo(id: id, type: agentType(full), lastActivityAt: mtime))
        }
        agents.sort { $0.lastActivityAt > $1.lastActivityAt }
        return (agents, newest)
    }

    /// サブエージェントの種別。ログと同時に書かれる meta.json に入っている。
    private mutating func agentType(_ path: String) -> String? {
        let metaPath = String(path.dropLast(".jsonl".count)) + ".meta.json"
        if let cached = agentTypes[metaPath] { return cached.isEmpty ? nil : cached }
        guard let data = FileManager.default.contents(atPath: metaPath),
              let o = JSONLoose.dict(JSONLoose.object(data)) else { return nil }
        let type = JSONLoose.string(o["agentType"])
        // 見つからない場合も覚える。空文字は「読んだが無かった」の意味。
        agentTypes[metaPath] = type ?? ""
        return type
    }
}
