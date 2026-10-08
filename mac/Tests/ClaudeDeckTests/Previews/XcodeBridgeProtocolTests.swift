import XCTest
@testable import MonitorKit

final class XcodeBridgeProtocolTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInitializeAndNotifications() throws {
        let initialize = try object(XcodeBridgeMessage.initialize(id: 1))
        XCTAssertEqual(initialize["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(initialize["id"] as? Int, 1)
        XCTAssertEqual(initialize["method"] as? String, "initialize")
        let params = try XCTUnwrap(initialize["params"] as? [String: Any])
        XCTAssertEqual(params["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((params["clientInfo"] as? [String: Any])?["name"] as? String, "claude-deck")
        let initialized = try object(XcodeBridgeMessage.initialized())
        XCTAssertNil(initialized["id"])
        XCTAssertEqual(initialized["method"] as? String, "notifications/initialized")
        XCTAssertFalse(XcodeBridgeMessage.initialize(id: 1).contains(0x0A))
    }

    func testCallToolOnlyAllowsReadAndRender() throws {
        let call = try object(XcodeBridgeMessage.callTool(id: 7, name: "RenderPreview", arguments: ["sourceFilePath": "a/B.swift"]))
        XCTAssertEqual(call["method"] as? String, "tools/call")
        let params = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "RenderPreview")
        XCTAssertEqual((params["arguments"] as? [String: Any])?["sourceFilePath"] as? String, "a/B.swift")
        for name in ["XcodeOpenWorkspace", "XcodeCloseWorkspace", "XcodeListWorkspaces", "XcodeGlob", "RenderPreview"] {
            XCTAssertTrue(XcodeBridgeTool.isAllowed(name), name)
        }
        for name in ["XcodeWrite", "XcodeUpdate", "XcodeRM", "XcodeMV", "RunProject", "BuildProject", "RunAllTests",
                     "UpdateTargetBuildSetting", "RunCodeSnippet", "renderpreview", ""] {
            XCTAssertThrowsError(try XcodeBridgeMessage.callTool(id: 1, name: name, arguments: [:]), name) { error in
                XCTAssertEqual(error as? XcodeBridgeFailure, .notAllowed(name))
            }
        }
    }

    func testParseIncoming() {
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","id":3,"result":{"a":1}}"#.utf8)),
                       .response(id: 3, result: Data(#"{"a":1}"#.utf8)))
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)),
                       .error(id: 4, message: "Method not found"))
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)),
                       .notification(method: "notifications/tools/list_changed"))
        XCTAssertEqual(XcodeBridgeMessage.parse(Data("not json".utf8)), .unreadable)
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"id":5}"#.utf8)), .unreadable)
        // 相手からの要求（ping）は id を数でも文字列でも受ける。
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8)),
                       .request(id: .number(9), method: "ping"))
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","id":"p-1","method":"ping"}"#.utf8)),
                       .request(id: .string("p-1"), method: "ping"))
        // id が null の失敗（要求を読めなかった）は id なしの失敗として返す。
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8)),
                       .error(id: nil, message: "Parse error"))
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid"}}"#.utf8)),
                       .error(id: nil, message: "Invalid"))
        XCTAssertEqual(XcodeBridgeMessage.parse(Data(#"{"jsonrpc":"2.0","id":true,"result":{}}"#.utf8)), .unreadable)
        XCTAssertEqual(XcodeBridgeMessage.toolNames(Data(#"{"tools":[{"name":"RenderPreview"},{"name":"XcodeGlob"}]}"#.utf8)),
                       ["RenderPreview", "XcodeGlob"])
    }

    func testPongAndMethodNotFound() throws {
        let pong = try object(XcodeBridgeMessage.pong(id: .number(9)))
        XCTAssertEqual(pong["id"] as? Int, 9)
        XCTAssertEqual((pong["result"] as? [String: Any])?.count, 0)
        XCTAssertNil(pong["error"])
        let stringPong = try object(XcodeBridgeMessage.pong(id: .string("p-1")))
        XCTAssertEqual(stringPong["id"] as? String, "p-1")
        let unknown = try object(XcodeBridgeMessage.methodNotFound(id: .number(3), method: "sampling/createMessage"))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNil(unknown["result"])
    }

    func testErrorPayloadWithoutIsErrorIsClassified() throws {
        // isError が false でも本文が {"type":"error",…} なら失敗として扱う。
        let text = try XCTUnwrap(XcodeToolResult.parse(Data(#"{"content":[{"type":"text","text":"{\"type\":\"error\",\"data\":\"Waiting for packages to load\"}"}]}"#.utf8)))
        XCTAssertFalse(text.isError)
        XCTAssertThrowsError(try text.decode(RenderPreviewResult.self)) { XCTAssertEqual($0 as? XcodeBridgeFailure, .packagesLoading) }
        let structured = try XCTUnwrap(XcodeToolResult.parse(Data(#"{"content":[],"structuredContent":{"type":"error","data":"Crashed"}}"#.utf8)))
        XCTAssertThrowsError(try structured.decode(RenderPreviewResult.self)) { XCTAssertEqual($0 as? XcodeBridgeFailure, .renderFailed("Crashed")) }
        // 種類が error でなければ通常どおり読む。
        let fine = try XCTUnwrap(XcodeToolResult.parse(Data(#"{"content":[],"structuredContent":{"type":"ok","displayName":"V"}}"#.utf8)))
        XCTAssertNil(fine.failureText)
        XCTAssertEqual(try fine.decode(RenderPreviewResult.self).displayName, "V")
    }

    func testWorkspaceListFindsIdentifiersAndPaths() {
        let message = """
        Open workspaces:
        - workspace-thw6oNbhPy: /Users/me/My Apps/random_talk.xcodeproj (active scheme: random_talk)
        - workspace-Ab_9: "/Users/me/b/App.xcworkspace/"
        """
        let list = XcodeWorkspaceList(message: message)
        XCTAssertTrue(list.contains(identifier: "workspace-thw6oNbhPy"))
        XCTAssertTrue(list.contains(identifier: "workspace-Ab_9"))
        XCTAssertFalse(list.contains(identifier: "workspaces"))
        XCTAssertTrue(list.contains(path: "/Users/me/My Apps/random_talk.xcodeproj"))
        XCTAssertTrue(list.contains(path: "/Users/me/b/App.xcworkspace"))
        XCTAssertTrue(list.contains(path: "/Users/me/b/./App.xcworkspace/"))
        XCTAssertFalse(list.contains(path: "/Users/me/random_talk.xcodeproj"))
        let empty = XcodeWorkspaceList(message: "No workspaces are currently open.")
        XCTAssertTrue(empty.identifiers.isEmpty)
        XCTAssertTrue(empty.paths.isEmpty)
        XCTAssertTrue(XcodeWorkspaceList(message: "workspace1 at /p/A.xcodeproj").contains(identifier: "workspace1"))
    }

    func testToolResultDecodesStructuredContent() throws {
        let data = Data(#"{"content":[{"type":"text","text":"{}"}],"structuredContent":{"workspaceIdentifier":"workspace-1","activeScheme":"App","activeRunDestination":"iPhone 18 Pro","workspacePath":"/p/App.xcodeproj"}}"#.utf8)
        let result = try XCTUnwrap(XcodeToolResult.parse(data))
        XCTAssertFalse(result.isError)
        let opened = try result.decode(XcodeOpenWorkspaceResult.self)
        XCTAssertEqual(opened.workspaceIdentifier, "workspace-1")
        XCTAssertEqual(opened.activeScheme, "App")
        // structuredContent が無ければ本文の text を JSON として読む。
        let textOnly = try XCTUnwrap(XcodeToolResult.parse(Data(#"{"content":[{"type":"text","text":"{\"matches\":[\"a/B.swift\"],\"truncated\":false,\"totalFound\":1}"}]}"#.utf8)))
        XCTAssertEqual(try textOnly.decode(XcodeGlobResult.self).matches, ["a/B.swift"])
        XCTAssertNil(XcodeToolResult.parse(Data("[]".utf8)))
    }

    func testToolErrorsAreClassified() throws {
        let unapproved = try XCTUnwrap(XcodeToolResult.parse(Data(#"{"isError":true,"content":[{"type":"text","text":"This agent isn't approved to use Xcode tools. Call XcodeOpenWorkspace first."}]}"#.utf8)))
        XCTAssertThrowsError(try unapproved.decode(XcodeGlobResult.self)) { XCTAssertEqual($0 as? XcodeBridgeFailure, .notApproved) }
        let waiting = "Xcode is waiting for the user to approve this request; it has been recorded. Ask the user to approve it from the Xcode MCP menu bar icon, or via `xcrun mcp-server`, then retry."
        XCTAssertEqual(XcodeBridgeFailure.classify(waiting), .notApproved)
        XCTAssertEqual(XcodeBridgeFailure.classify(#"{"type":"error","data":"PreviewBlockedReason: Waiting for packages to load\n\nWait to update previews until all package loading is complete\n\ntearingDown"}"#),
                       .packagesLoading)
        XCTAssertEqual(XcodeBridgeFailure.classify("Build failed: Cannot find 'Purchases' in scope"),
                       .buildFailed("Build failed: Cannot find 'Purchases' in scope"))
        let log = """
        PreviewFailedError: Preview errored.

        |  SchemeBuildError: Failed to build the scheme “ailovei”
        |  |  Planning Swift module ailovei (arm64):
        |  |  /p/ios/ailovei/App.swift:9:8: error: Unable to resolve Swift module dependency: 'RevenueCat'
        |  |      note: Found incompatible module
        """
        XCTAssertEqual(XcodeBridgeFailure.classify(log),
                       .buildFailed("/p/ios/ailovei/App.swift:9:8: error: Unable to resolve Swift module dependency: 'RevenueCat'"))
        XCTAssertEqual(XcodeBridgeFailure.classify("Xcode is not running"), .xcodeNotRunning)
        XCTAssertEqual(XcodeBridgeFailure.classify(#"{"type":"error","data":"Crashed"}"#), .renderFailed("Crashed"))
        let long = String(repeating: "x", count: 1000)
        if case .renderFailed(let detail) = XcodeBridgeFailure.classify(long) {
            XCTAssertEqual(detail.count, 601)
        } else {
            XCTFail("renderFailed")
        }
    }

    func testFailureStopsQueueOnlyForSharedCauses() {
        XCTAssertTrue(XcodeBridgeFailure.xcodeNotRunning.stopsQueue)
        XCTAssertTrue(XcodeBridgeFailure.notApproved.stopsQueue)
        XCTAssertTrue(XcodeBridgeFailure.buildFailed("x").stopsQueue)
        XCTAssertFalse(XcodeBridgeFailure.renderFailed("x").stopsQueue)
        XCTAssertFalse(XcodeBridgeFailure.timedOut(300).stopsQueue)
        XCTAssertFalse(XcodeBridgeFailure.notInProject("a").stopsQueue)
        XCTAssertFalse(XcodeBridgeFailure.ambiguousInProject("a").stopsQueue)
        XCTAssertEqual(XcodeBridgeFailure.xcodeNotRunning.message, "Xcode を起動すると描けます")
    }

    func testRenderResult() throws {
        let data = Data(#"{"displayName":"広告あり","previewSnapshotPath":"/var/folders/x/a.png","renderedDestination":{"deviceModelName":"iPhone 18 Pro","platformName":"iOS","systemVersion":"27.0"},"sourceLineNumber":200,"supportedLocalizations":["en","ja"],"supportedPreviewVariantOverrides":{"Color Scheme":["Light Appearance","Dark Appearance"]},"errors":[]}"#.utf8)
        let result = try JSONDecoder().decode(RenderPreviewResult.self, from: data)
        XCTAssertEqual(try result.snapshot(), "/var/folders/x/a.png")
        XCTAssertEqual(result.renderedDestination?.label, "iPhone 18 Pro・iOS 27.0")
        let info = PreviewSnapshotInfo(result: result, renderedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(info.supportedVariants["Color Scheme"], ["Light Appearance", "Dark Appearance"])
        XCTAssertEqual(info.supportedLocalizations, ["en", "ja"])
        XCTAssertEqual(info.sourceLineNumber, 200)

        let failed = try JSONDecoder().decode(RenderPreviewResult.self, from: Data(#"{"errors":[{"message":"Build failed"},{"message":"error: x"}]}"#.utf8))
        XCTAssertThrowsError(try failed.snapshot()) { XCTAssertEqual($0 as? XcodeBridgeFailure, .buildFailed("error: x")) }
        let empty = try JSONDecoder().decode(RenderPreviewResult.self, from: Data("{}".utf8))
        XCTAssertThrowsError(try empty.snapshot()) { XCTAssertEqual($0 as? XcodeBridgeFailure, .renderFailed("絵が返りませんでした")) }
    }

    func testRenderArguments() {
        let plain = RenderPreviewArguments(workspaceIdentifier: "w", sourceFilePath: "App/V.swift", index: 2, timeout: 300).json
        XCTAssertEqual(plain["previewDefinitionIndexInFile"] as? Int, 2)
        XCTAssertEqual(plain["timeout"] as? Int, 300)
        XCTAssertNil(plain["previewVariantOverrides"])
        XCTAssertNil(plain["previewLocalizationOverride"])
        let variant = RenderPreviewArguments(workspaceIdentifier: "w", sourceFilePath: "App/V.swift", index: 0,
                                             variants: ["Color Scheme": "Dark Appearance"], locale: "ja", timeout: 60).json
        XCTAssertEqual(variant["previewVariantOverrides"] as? [String: String], ["Color Scheme": "Dark Appearance"])
        XCTAssertEqual(variant["previewLocalizationOverride"] as? String, "ja")
    }

    func testProjectPathMatching() {
        let matches = ["random_talk/Features/Matching/Views/RadarView.swift", "random_talk/Old/RadarView.swift", "Other/X.swift"]
        XCTAssertEqual(XcodeProjectPaths.match(matches, relativePath: "Features/Matching/Views/RadarView.swift"),
                       .found("random_talk/Features/Matching/Views/RadarView.swift"))
        XCTAssertEqual(XcodeProjectPaths.match(matches, relativePath: "Old/RadarView.swift"), .found("random_talk/Old/RadarView.swift"))
        // 候補が 1 つなら、ファイル名だけの一致でも使う（グループの名前がフォルダと違う時）。
        XCTAssertEqual(XcodeProjectPaths.match(["App/A.swift"], relativePath: "./Sources/A.swift"), .found("App/A.swift"))
        XCTAssertEqual(XcodeProjectPaths.match(matches, relativePath: "Features/Missing.swift"), .notFound)
        XCTAssertEqual(XcodeProjectPaths.match([], relativePath: "A.swift"), .notFound)
        // ファイル名だけの一致で候補が複数・最高点が同点なら、別のファイルを描かないよう決めない。
        XCTAssertEqual(XcodeProjectPaths.match(matches, relativePath: "New/RadarView.swift"), .ambiguous)
        XCTAssertEqual(XcodeProjectPaths.match(["A/Views/V.swift", "B/Views/V.swift"], relativePath: "Views/V.swift"), .ambiguous)
        XCTAssertEqual(XcodeProjectPaths.match(["A/Views/V.swift", "B/Views/V.swift"], relativePath: "A/Views/V.swift"), .found("A/Views/V.swift"))
        // 同じパスが重ねて返っても 1 つとして数える。
        XCTAssertEqual(XcodeProjectPaths.match(["App/A.swift", "App/A.swift"], relativePath: "A.swift"), .found("App/A.swift"))
        // 打ち切られた結果では、見つかっても決めない（打ち切られた先にもっと合う候補がありうるため）。
        XCTAssertEqual(XcodeProjectPaths.match(matches, truncated: true, relativePath: "Features/Matching/Views/RadarView.swift"), .ambiguous)
        XCTAssertEqual(XcodeProjectPaths.match([], truncated: true, relativePath: "A.swift"), .ambiguous)
        XCTAssertEqual(XcodeProjectPaths.globPattern(forFileName: "RadarView.swift"), "**/RadarView.swift")
        XCTAssertEqual(XcodeProjectPaths.globPattern(forFileName: "View[1].swift"), "**/*.swift")
    }

    func testVariantLabels() {
        XCTAssertEqual(PreviewVariantLabels.label(for: "Color Scheme"), "外観")
        XCTAssertEqual(PreviewVariantLabels.label(for: "Unknown"), "Unknown")
        XCTAssertEqual(PreviewVariantLabels.ordered(["Orientation", "Zeta", "Color Scheme", "Alpha", "Dynamic Type"]),
                       ["Color Scheme", "Dynamic Type", "Orientation", "Alpha", "Zeta"])
    }

    func testBuildErrorsSkipDiagnosticNotesAndDuplicates() {
        let log = """
        |  SchemeBuildError: Failed to build the scheme “ailovei”
        |  |  /x/PaywallColor.swift:57:12: error: invalid redeclaration
        |  |      |            `- error: invalid redeclaration
        |  |  /x/PaywallColor.swift:57:12: error: invalid redeclaration
        |  |  /x/PaywallColor.swift:260:18: error: ambiguous use of 'init'
        """
        XCTAssertEqual(XcodeBridgeFailure.classify(log),
                       .buildFailed("/x/PaywallColor.swift:57:12: error: invalid redeclaration\n/x/PaywallColor.swift:260:18: error: ambiguous use of 'init'"))
    }
}
