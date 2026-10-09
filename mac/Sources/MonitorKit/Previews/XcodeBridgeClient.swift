import Foundation

/// mcpbridge の MCP クライアント。要求は 1 件ずつ送り、時間切れになったら（相手の状態が分からないので）mcpbridge ごと止める。
public actor XcodeBridgeClient {
    /// 応答を待つ時間。
    public struct Timeouts: Sendable {
        /// 起動の握手（initialize・tools/list）。
        public var handshake: Duration = .seconds(30)
        /// プロジェクトを開く（未承認なら Xcode が人の許可を 1 分ほど待ってから返す）。
        public var open: Duration = .seconds(180)
        public var short: Duration = .seconds(30)
        /// 開く前の一覧（返らない時は諦めて、自分で開いたとはみなさずに開く）。
        public var list: Duration = .seconds(10)
        /// RenderPreview に渡す時間切れに足す余裕。
        public var renderMargin: Duration = .seconds(30)

        public init() {}
    }

    private let launch: XcodeBridgeLaunch
    private let timeouts: Timeouts
    private var transport: (any XcodeBridgeTransport)?
    private var reader: Task<Void, Never>?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Result<Data, XcodeBridgeFailure>, Never>] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    /// 止めている途中の mcpbridge（止め切る前に次を起動しないため）。
    private var stopping: Task<Void, Never>?
    /// 起動してからツールを呼んだ回数（開く前の一覧は最初の呼び出しでしか確かに返らないため）。
    private var callsSinceStart = 0

    public init(timeouts: Timeouts = Timeouts(), launch: @escaping XcodeBridgeLaunch) {
        self.launch = launch
        self.timeouts = timeouts
    }

    public var isRunning: Bool { transport != nil }

    /// 動いていなければ起動して握手し、RenderPreview があるか確かめる。
    public func start() async throws {
        try await serialized {
            guard transport == nil else { return }
            await stopping?.value
            stopping = nil
            let (stream, continuation) = AsyncStream<XcodeBridgeEvent>.makeStream()
            let transport: any XcodeBridgeTransport
            do {
                transport = try launch(continuation)
            } catch {
                throw XcodeBridgeFailure.bridgeUnavailable("mcpbridge を起動できませんでした（\(error)）")
            }
            generation += 1
            let current = generation
            self.transport = transport
            reader = Task { [weak self] in
                for await event in stream { await self?.handle(event, generation: current) }
                await self?.handle(.exited(""), generation: current)
            }
            do {
                _ = try await request(XcodeBridgeMessage.initialize(id: takeId()), timeout: timeouts.handshake)
                try transport.send(XcodeBridgeMessage.initialized())
                let tools = try await request(XcodeBridgeMessage.toolsList(id: takeId()), timeout: timeouts.handshake)
                guard XcodeBridgeMessage.toolNames(tools).contains(XcodeBridgeTool.renderPreview.rawValue) else {
                    throw XcodeBridgeFailure.unsupported
                }
                callsSinceStart = 0
            } catch {
                await shutdown()
                throw error
            }
        }
    }

    public func openWorkspace(path: String) async throws -> XcodeOpenWorkspaceResult {
        try await call(.openWorkspace, ["path": path], timeout: timeouts.open).decode(XcodeOpenWorkspaceResult.self)
    }

    public func closeWorkspace(_ identifier: String) async throws {
        try await call(.closeWorkspace, ["workspaceIdentifier": identifier], timeout: timeouts.short).throwIfFailed()
    }

    /// Xcode で開いているワークスペースの一覧（文言のまま）。
    public func listWorkspaces() async throws -> XcodeWorkspaceList {
        let result = try await call(.listWorkspaces, [:], timeout: timeouts.list)
        try result.throwIfFailed()
        let message = (try? result.decode(XcodeListWorkspacesResult.self))?.message ?? result.text
        return XcodeWorkspaceList(message: message)
    }

    /// 開く前に一覧を見て、利用者が既に開いていた（一覧を読めない時も）なら自分で開いたとはみなさない（閉じないため）。
    public func openOwnedWorkspace(path: String) async throws -> XcodeOpenedWorkspace {
        // 何も開いていない時の一覧は、起動して最初の呼び出しでないと返らない（Xcode 27 の mcpbridge で確認）ので起動し直す。
        if callsSinceStart > 0 {
            await shutdown()
            try await start()
        }
        let before = try? await listWorkspaces()
        // 一覧が時間切れで mcpbridge ごと止まった時は起動し直して開く（その時は閉じない）。
        if transport == nil { try await start() }
        let opened = try await openWorkspace(path: path)
        let openedByUs = before.map { !$0.contains(path: path) && !$0.contains(identifier: opened.workspaceIdentifier) } ?? false
        return XcodeOpenedWorkspace(identifier: opened.workspaceIdentifier, openedByUs: openedByUs)
    }

    public func glob(workspace: String, pattern: String) async throws -> XcodeGlobResult {
        try await call(.glob, ["workspaceIdentifier": workspace, "pattern": pattern], timeout: timeouts.short)
            .decode(XcodeGlobResult.self)
    }

    /// 描いて結果を返す（絵が無ければ理由を投げる）。開いた直後のパッケージの読み込み中は `packagesWait` の間だけ頼み直す。
    public func renderPreview(_ arguments: RenderPreviewArguments, packagesWait: Duration = .seconds(180),
                              retryInterval: Duration = .seconds(3)) async throws -> RenderPreviewResult {
        let clock = ContinuousClock()
        let deadline = clock.now + packagesWait
        while true {
            do {
                let result = try await call(.renderPreview, arguments.json, timeout: .seconds(arguments.timeout) + timeouts.renderMargin,
                                            timeoutSeconds: arguments.timeout)
                    .decode(RenderPreviewResult.self)
                _ = try result.snapshot()
                return result
            } catch XcodeBridgeFailure.packagesLoading where clock.now + retryInterval < deadline {
                try await Task.sleep(for: retryInterval)
            }
        }
    }

    /// 止める（stdin を閉じてグループごと）。待っている要求は失敗で返す。止め切るまで待つ。
    public func stop() async {
        await shutdown()
        await stopping?.value
    }

    // MARK: - 中身

    private func call(_ tool: XcodeBridgeTool, _ arguments: [String: Any], timeout: Duration,
                      timeoutSeconds: Int? = nil) async throws -> XcodeToolResult {
        let message = try XcodeBridgeMessage.callTool(id: takeId(), name: tool.rawValue, arguments: arguments)
        return try await serialized {
            guard transport != nil else { throw XcodeBridgeFailure.bridgeUnavailable("mcpbridge が動いていません") }
            callsSinceStart += 1
            let data = try await request(message, timeout: timeout, timeoutSeconds: timeoutSeconds)
            guard let result = XcodeToolResult.parse(data) else { throw XcodeBridgeFailure.protocolError("tools/call の結果") }
            return result
        }
    }

    /// 前の要求が終わるまで待ってから `body` を通す（actor の再入で要求が重ならないように）。
    private func serialized<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    private func takeId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    private func request(_ message: Data, timeout: Duration, timeoutSeconds: Int? = nil) async throws -> Data {
        guard let transport, let id = Self.requestId(message) else { throw XcodeBridgeFailure.bridgeUnavailable("mcpbridge が動いていません") }
        let seconds = timeoutSeconds ?? Int(timeout.components.seconds)
        let result: Result<Data, XcodeBridgeFailure> = await withCheckedContinuation { continuation in
            pending[id] = continuation
            do {
                try transport.send(message)
            } catch {
                pending.removeValue(forKey: id)?.resume(returning: .failure(.bridgeUnavailable("mcpbridge に書けませんでした")))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id, seconds: seconds)
            }
        }
        return try result.get()
    }

    private static func requestId(_ message: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: message)) as? [String: Any]).flatMap { ($0["id"] as? NSNumber)?.intValue }
    }

    private func expire(_ id: Int, seconds: Int) async {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: .failure(.timedOut(seconds)))
        // 遅れて届く応答と次の要求が食い違わないよう、相手ごと止めて次は起動し直す。
        await shutdown()
    }

    private func handle(_ event: XcodeBridgeEvent, generation current: Int) async {
        guard current == generation else { return }
        switch event {
        case .line(let line):
            switch XcodeBridgeMessage.parse(line) {
            case .response(let id, let result):
                pending.removeValue(forKey: id)?.resume(returning: .success(result))
            case .error(let id, let message):
                let failure = XcodeBridgeFailure.classify(message)
                let reported: XcodeBridgeFailure = if case .renderFailed = failure { .toolError(message) } else { failure }
                // id が null なら相手は要求を読めていないので、待っている 1 件（直列なので最古）を失敗にする。
                guard let key = id ?? pending.keys.min() else { break }
                pending.removeValue(forKey: key)?.resume(returning: .failure(reported))
            case .request(let id, let method):
                let reply = method == "ping" ? XcodeBridgeMessage.pong(id: id) : XcodeBridgeMessage.methodNotFound(id: id, method: method)
                try? transport?.send(reply)
            case .notification, .unreadable:
                break
            }
        case .exited(let detail):
            let reason = detail.isEmpty ? "mcpbridge が終了しました" : "mcpbridge が終了しました: \(XcodeBridgeFailure.summary(detail, limit: 300))"
            // Xcode が無くて終わった時はそう言う。
            failAll(XcodeBridgeFailure.classify(reason) == .xcodeNotRunning ? .xcodeNotRunning : .bridgeUnavailable(reason))
            await shutdown()
        }
    }

    private func failAll(_ failure: XcodeBridgeFailure) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(returning: .failure(failure)) }
    }

    private func shutdown() async {
        failAll(.bridgeUnavailable("mcpbridge を止めました"))
        guard let transport else { return }
        self.transport = nil
        generation += 1
        reader?.cancel()
        reader = nil
        let previous = stopping
        let task = Task {
            await previous?.value
            await transport.stop()
        }
        stopping = task
        await task.value
    }
}
