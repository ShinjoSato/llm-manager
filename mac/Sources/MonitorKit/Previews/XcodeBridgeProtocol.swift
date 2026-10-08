import Foundation

/// mcpbridge（Xcode の MCP）で呼んでよいツール。読み取りと描画だけで、ファイルの書き換え・Run・テスト等は呼ばない。
public enum XcodeBridgeTool: String, CaseIterable, Sendable {
    case openWorkspace = "XcodeOpenWorkspace"
    case closeWorkspace = "XcodeCloseWorkspace"
    case listWorkspaces = "XcodeListWorkspaces"
    case glob = "XcodeGlob"
    case renderPreview = "RenderPreview"

    public static func isAllowed(_ name: String) -> Bool { XcodeBridgeTool(rawValue: name) != nil }
}

/// 描けなかった理由。
public enum XcodeBridgeFailure: Error, Equatable, Sendable {
    case xcodeNotRunning
    case notApproved
    /// この Xcode に RenderPreview が無い。
    case unsupported
    case buildFailed(String)
    /// 開いた直後でパッケージを読み込んでいる（少し待てば描ける）。
    case packagesLoading
    case timedOut(Int)
    case renderFailed(String)
    /// Xcode のプロジェクトにそのファイルが無い。
    case notInProject(String)
    /// mcpbridge を起動できない・途中で終わった。
    case bridgeUnavailable(String)
    case toolError(String)
    case protocolError(String)
    case notAllowed(String)

    public var message: String {
        switch self {
        case .xcodeNotRunning: return "Xcode を起動すると描けます"
        case .notApproved:
            return "Xcode が claude-deck からの接続をまだ許可していません。メニューバーの Xcode の MCP のアイコンから許可してから描き直してください"
        case .unsupported: return "この Xcode ではプレビューを描けません（RenderPreview のある Xcode 27 以降が要ります）"
        case .buildFailed(let detail): return "ビルドに失敗しました: \(detail)"
        case .packagesLoading: return "Xcode がパッケージを読み込み終えていません。しばらくしてから描き直してください"
        case .timedOut(let seconds): return "時間切れ（\(seconds) 秒）で描けませんでした"
        case .renderFailed(let detail): return "このプレビューは描けませんでした: \(detail)"
        case .notInProject(let file): return "\(file) が Xcode のプロジェクトに見つかりません"
        case .bridgeUnavailable(let detail): return "Xcode とつなげませんでした: \(detail)"
        case .toolError(let detail): return "Xcode がエラーを返しました: \(detail)"
        case .protocolError(let detail): return "Xcode の応答を読めませんでした: \(detail)"
        case .notAllowed(let name): return "\(name) は呼ばない決まりです"
        }
    }

    /// 1 件だけの失敗ではなく、続けても同じ失敗になるもの（残りを止める）。
    public var stopsQueue: Bool {
        switch self {
        case .xcodeNotRunning, .notApproved, .unsupported, .buildFailed, .bridgeUnavailable, .notAllowed: return true
        case .packagesLoading, .timedOut, .renderFailed, .notInProject, .toolError, .protocolError: return false
        }
    }

    /// ツールが返した文言から種類を見分ける。
    public static func classify(_ text: String) -> XcodeBridgeFailure {
        let text = unwrapped(text)
        let lower = text.lowercased()
        // 未承認は「Call XcodeOpenWorkspace first」、承認待ちは「waiting for the user to approve」と返る。
        if lower.contains("isn't approved") || lower.contains("not approved") || lower.contains("isn’t approved")
            || lower.contains("waiting for the user to approve") { return .notApproved }
        if lower.contains("xcode is not running") || lower.contains("xcode isn't running") || lower.contains("no running xcode") {
            return .xcodeNotRunning
        }
        if lower.contains("waiting for packages to load") { return .packagesLoading }
        if lower.contains("build failed") || lower.contains("failed to build") || lower.contains("build error")
            || lower.contains("compiling failed") || lower.contains("compilation failed") {
            return .buildFailed(buildErrors(text) ?? summary(text))
        }
        return .renderFailed(summary(text))
    }

    /// RenderPreview のエラーは `{"type":"error","data":"…"}` の形で返ることがあるので、中の文言を取り出す。
    static func unwrapped(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let data = object["data"] as? String ?? object["message"] as? String else { return text }
        return data
    }

    /// ビルドログ（`|` の枠で入れ子になる）から `error:` の行だけを先頭から数行取り出す。
    static func buildErrors(_ text: String, limit: Int = 3) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { line in
            String(line.drop(while: { $0 == "|" || $0 == " " || $0 == "\t" }))
        }
        let errors = lines.filter { $0.contains("error:") }
        return errors.isEmpty ? nil : summary(errors.prefix(limit).joined(separator: "\n"))
    }

    /// 長いビルドログを画面に出せる長さに縮める。
    static func summary(_ text: String, limit: Int = 600) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

/// mcpbridge から届いた 1 行。
public enum XcodeBridgeIncoming: Equatable, Sendable {
    /// 成功の応答（`result` の JSON）。
    case response(id: Int, result: Data)
    case error(id: Int, message: String)
    case notification(method: String)
    case unreadable
}

/// JSON-RPC 2.0（1 行 1 メッセージ）の組み立てと読み取り。
public enum XcodeBridgeMessage {
    public static let protocolVersion = "2025-06-18"
    public static let clientName = "claude-deck"

    public static func initialize(id: Int, version: String = "1") -> Data {
        encode(["jsonrpc": "2.0", "id": id, "method": "initialize",
                "params": ["protocolVersion": protocolVersion, "capabilities": [String: Any](),
                           "clientInfo": ["name": clientName, "version": version]]])
    }

    public static func initialized() -> Data {
        encode(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    public static func toolsList(id: Int) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "method": "tools/list"])
    }

    /// 許可のないツールは組み立てない。
    public static func callTool(id: Int, name: String, arguments: [String: Any]) throws -> Data {
        guard XcodeBridgeTool.isAllowed(name) else { throw XcodeBridgeFailure.notAllowed(name) }
        return encode(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        // 中身は自前で組んだ辞書だけなので失敗しない。
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public static func parse(_ line: Data) -> XcodeBridgeIncoming {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .unreadable }
        guard let id = (object["id"] as? NSNumber)?.intValue else {
            if let method = object["method"] as? String { return .notification(method: method) }
            return .unreadable
        }
        if let error = object["error"] as? [String: Any] {
            return .error(id: id, message: error["message"] as? String ?? "不明なエラー")
        }
        guard let result = object["result"],
              let data = try? JSONSerialization.data(withJSONObject: result) else { return .unreadable }
        return .response(id: id, result: data)
    }

    /// tools/list の結果に含まれるツール名。
    public static func toolNames(_ result: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }
    }
}

/// tools/call の結果（`isError`・本文の text・`structuredContent`）。
public struct XcodeToolResult: Equatable, Sendable {
    public var isError: Bool
    public var text: String
    public var structured: Data?

    public static func parse(_ result: Data) -> XcodeToolResult? {
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else { return nil }
        let isError = (object["isError"] as? NSNumber)?.boolValue ?? false
        let text = (object["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        let structured = (object["structuredContent"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return XcodeToolResult(isError: isError, text: text, structured: structured)
    }

    /// エラーなら理由を、そうでなければ structuredContent を型に読む（無ければ本文の text を JSON として読む）。
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if isError { throw XcodeBridgeFailure.classify(text) }
        let source = structured ?? Data(text.utf8)
        do {
            return try JSONDecoder().decode(type, from: source)
        } catch {
            throw XcodeBridgeFailure.protocolError(XcodeBridgeFailure.summary(text.isEmpty ? "\(error)" : text, limit: 200))
        }
    }
}

public struct XcodeOpenWorkspaceResult: Decodable, Equatable, Sendable {
    public var workspaceIdentifier: String
    public var workspacePath: String?
    public var activeScheme: String?
    public var activeRunDestination: String?
    public var message: String?
}

public struct XcodeGlobResult: Decodable, Equatable, Sendable {
    public var matches: [String]
    public var truncated: Bool?
    public var totalFound: Int?
}

/// 描いた端末。
public struct RenderedDestination: Codable, Equatable, Sendable {
    public var deviceModelName: String?
    public var platformName: String?
    public var systemVersion: String?

    public init(deviceModelName: String? = nil, platformName: String? = nil, systemVersion: String? = nil) {
        self.deviceModelName = deviceModelName
        self.platformName = platformName
        self.systemVersion = systemVersion
    }

    /// 「iPhone 17 Pro・iOS 27.0」。
    public var label: String? {
        let parts = [deviceModelName, systemVersion.map { "iOS \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

public struct RenderPreviewResult: Decodable, Equatable, Sendable {
    public struct Message: Decodable, Equatable, Sendable {
        public var message: String
    }

    public var displayName: String?
    public var errors: [Message]?
    public var previewSnapshotPath: String?
    public var renderedDestination: RenderedDestination?
    public var sourceLineNumber: Int?
    public var supportedLocalizations: [String]?
    public var supportedPreviewVariantOverrides: [String: [String]]?

    /// 絵が無ければ、返ったエラーから理由を作る。
    public func snapshot() throws -> String {
        if let path = previewSnapshotPath, !path.isEmpty { return path }
        let text = (errors ?? []).map(\.message).joined(separator: "\n")
        throw text.isEmpty ? XcodeBridgeFailure.renderFailed("絵が返りませんでした") : XcodeBridgeFailure.classify(text)
    }
}

/// RenderPreview に渡す引数。
public struct RenderPreviewArguments: Equatable, Sendable {
    public var workspaceIdentifier: String
    public var sourceFilePath: String
    public var index: Int
    public var variants: [String: String]
    public var locale: String?
    public var timeout: Int

    public init(workspaceIdentifier: String, sourceFilePath: String, index: Int, variants: [String: String] = [:],
                locale: String? = nil, timeout: Int) {
        self.workspaceIdentifier = workspaceIdentifier
        self.sourceFilePath = sourceFilePath
        self.index = index
        self.variants = variants
        self.locale = locale
        self.timeout = timeout
    }

    public var json: [String: Any] {
        var args: [String: Any] = ["workspaceIdentifier": workspaceIdentifier, "sourceFilePath": sourceFilePath,
                                   "previewDefinitionIndexInFile": index, "timeout": timeout]
        if !variants.isEmpty { args["previewVariantOverrides"] = variants }
        if let locale, !locale.isEmpty { args["previewLocalizationOverride"] = locale }
        return args
    }
}

/// ディスク上のファイルと、Xcode のプロジェクトの中のパス（グループの並び）の対応。
public enum XcodeProjectPaths {
    /// Glob の型（`*?[]{}`）を含まないファイル名ならその名前で、含めば Swift ファイル全体で探す。
    public static func globPattern(forFileName name: String) -> String {
        let special: Set<Character> = ["*", "?", "[", "]", "{", "}", "\\"]
        return name.contains(where: { special.contains($0) }) ? "**/*.swift" : "**/\(name)"
    }

    /// 末尾から一致する区間がいちばん長い候補（同じなら先のもの）。ファイル名が一致しなければ nil。
    public static func bestMatch(_ matches: [String], relativePath: String) -> String? {
        let target = components(relativePath)
        var best: (path: String, score: Int)?
        for match in matches {
            let parts = components(match)
            var score = 0
            while score < min(parts.count, target.count),
                  parts[parts.count - 1 - score] == target[target.count - 1 - score] { score += 1 }
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (match, score) }
        }
        return best?.path
    }

    private static func components(_ path: String) -> [Substring] {
        path.split(separator: "/").filter { $0 != "." }
    }
}

/// 切り替えの名前（Xcode のキャンバスの項目名）の日本語。
public enum PreviewVariantLabels {
    public static func label(for group: String) -> String {
        switch group {
        case "Color Scheme": return "外観"
        case "Dynamic Type": return "文字の大きさ"
        case "Orientation": return "向き"
        case "Contrast": return "コントラスト"
        case "Control Borders": return "ボタンの枠"
        default: return group
        }
    }

    /// 画面に出す順（よく使うものを先に）。
    public static func ordered(_ groups: [String]) -> [String] {
        let preferred = ["Color Scheme", "Dynamic Type", "Orientation", "Contrast", "Control Borders"]
        return groups.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? preferred.count, ib = preferred.firstIndex(of: b) ?? preferred.count
            return ia != ib ? ia < ib : a < b
        }
    }
}
