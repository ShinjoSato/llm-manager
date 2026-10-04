import Foundation

/// チャネル本体。stdin の JSON-RPC を読み、権限確認を中継して判断を stdout に返す。stdout は JSON-RPC の通り道なので、ログは stderr へ。
public final class ChannelServer: @unchecked Sendable {
    /// SDK の ReadBuffer と同じ上限。超えたら読みかけを捨てる。
    static let maxLineBytes = 10 * 1024 * 1024

    private let baseURL: String
    private let pid: Int32
    private let cwd: String
    private let output: FileHandle
    private let errors: FileHandle
    private let writeLock = NSLock()
    private let session: URLSession

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                pid: Int32 = getppid(),
                cwd: String = FileManager.default.currentDirectoryPath,
                output: FileHandle = .standardOutput,
                errors: FileHandle = .standardError) {
        self.pid = pid
        self.cwd = cwd
        self.output = output
        self.errors = errors
        session = ChannelRelay.makeSession()
        baseURL = ChannelRelay.baseURL(environment) { message in
            try? errors.write(contentsOf: Data("[claude-deck-channel] \(message)\n".utf8))
        }
    }

    /// stdin が閉じる（Claude Code が終わる）まで読み続ける。
    public func run(input: FileHandle = .standardInput) async {
        log("接続しました（宛先 \(baseURL) / セッション PID \(pid)）")
        var buffer: [UInt8] = []
        var discarding = false
        do {
            for try await byte in input.bytes {
                guard byte == 0x0A else {
                    if !discarding { buffer.append(byte) }
                    if buffer.count > Self.maxLineBytes {
                        buffer.removeAll()
                        discarding = true
                        log("1 行が長すぎるので読み捨てます")
                    }
                    continue
                }
                if !discarding { handle(line: String(decoding: buffer, as: UTF8.self)) }
                buffer.removeAll(keepingCapacity: true)
                discarding = false
            }
        } catch {
            log("標準入力を読めません: \(error)")
        }
    }

    func handle(line: String) {
        switch ChannelProtocol.handle(line: line) {
        case .reply(let text):
            write(text)
        case .permissionRequest(let request):
            Task { await relay(request) }
        case .ignore:
            break
        }
    }

    private func relay(_ request: ChannelPermissionRequest) async {
        let body = ChannelRelay.requestBody(request, pid: pid, cwd: cwd)
        let log: @Sendable (String) -> Void = { [weak self] in self?.log($0) }
        let relay = ChannelRelay(ask: ChannelRelay.httpAsk(baseURL: baseURL, body: body, session: session, log: log), log: log)
        guard let decision = await relay.run(toolName: request.toolName, baseURL: baseURL) else { return }
        write(ChannelProtocol.permissionNotification(requestId: request.requestId, decision: decision))
    }

    private func write(_ line: String) {
        writeLock.withLock { try? output.write(contentsOf: Data((line + "\n").utf8)) }
    }

    func log(_ message: String) {
        try? errors.write(contentsOf: Data("[claude-deck-channel] \(message)\n".utf8))
    }
}
