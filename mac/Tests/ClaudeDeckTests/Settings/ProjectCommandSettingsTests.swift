import XCTest
@testable import MonitorKit

final class ProjectCommandSettingsTests: XCTestCase {
    private func project(_ json: String) throws -> ManagedProject {
        let file = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active"\#(json)}]}"#
        guard case .loaded(let settings) = SettingsFile.decode(Data(file.utf8)) else {
            XCTFail("読めない")
            throw CocoaError(.coderReadCorrupt)
        }
        return settings.projects[0]
    }

    func testCommandsRoundTripAndAreWrittenOnlyWhenPresent() throws {
        let settings = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/a", commands: [ProjectCommand(name: "dev", command: "npm run dev"),
                                                             ProjectCommand(name: "test", command: "cd web\nnpm test", icon: "testtube.2")]),
            ManagedProject(name: "b", path: "/b"),
        ])
        let data = try settings.encoded()
        XCTAssertEqual(SettingsFile.decode(data), .loaded(settings))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        let commands = try XCTUnwrap(projects[0]["commands"] as? [[String: Any]])
        XCTAssertEqual(commands[0].keys.sorted(), ["command", "name"])
        XCTAssertEqual(commands[1]["icon"] as? String, "testtube.2")
        XCTAssertNil(projects[1]["commands"])
        // 無いファイル・null も読める。
        XCTAssertEqual(try project("").commands, [])
        XCTAssertEqual(try project(#","commands":null"#).commands, [])
        XCTAssertFalse(try project(#","commands":null"#).ignoredCommands.isSet)
    }

    /// 形が崩れた `commands` はそのキーだけ捨てて警告にし、設定全体は読める。保存すると書かれない。
    func testMalformedCommandsAreIgnoredWithWarning() throws {
        for bad in [#","commands":"npm run dev""#, #","commands":[{"name":"dev"}]"#, #","commands":[{"name":1,"command":"x"}]"#] {
            let loaded = try project(bad + #","site":{"path":"site"}"#)
            XCTAssertEqual(loaded.commands, [], bad)
            XCTAssertTrue(loaded.ignoredCommands.isSet, bad)
            XCTAssertEqual(loaded.site?.path, "site")
            let warnings = SettingsValidation.warnings(DeckSettings(projects: [loaded]))
            XCTAssertTrue(warnings.contains { $0.contains("実行コマンド: 形が正しくないため無視しました") }, bad)
            let data = try DeckSettings(projects: [loaded]).encoded()
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("commands"))
        }
    }

    func testValidationOfNameBodyLengthAndDuplicates() {
        XCTAssertEqual(SettingsValidation.projectCommandProblems(ProjectCommand(name: " dev ", command: "npm run dev")), [])
        XCTAssertEqual(SettingsValidation.projectCommandProblems(ProjectCommand(name: "  ", command: "x")), ["コマンドの名前を入れてください"])
        XCTAssertEqual(SettingsValidation.projectCommandProblems(ProjectCommand(name: "a", command: " \n ")), ["実行するコマンドを入れてください"])
        let longName = String(repeating: "あ", count: ProjectCommands.nameLimit + 1)
        XCTAssertEqual(SettingsValidation.projectCommandProblems(ProjectCommand(name: longName, command: "x")),
                       ["コマンドの名前は \(ProjectCommands.nameLimit) 文字までです"])
        XCTAssertEqual(SettingsValidation.projectCommandProblems(ProjectCommand(name: "a\nb", command: "x")), ["コマンドの名前は 1 行にしてください"])
        let longBody = String(repeating: "x", count: ProjectCommands.commandLimit + 1)
        XCTAssertEqual(SettingsValidation.projectCommandProblems(ProjectCommand(name: "a", command: longBody)),
                       ["コマンドは \(ProjectCommands.commandLimit) 文字までです"])

        let rows = SettingsValidation.projectCommandRowProblems([
            ProjectCommand(name: "dev", command: "a"), ProjectCommand(name: " dev", command: "b"), ProjectCommand(name: "", command: "c"),
        ])
        XCTAssertEqual(rows, [[], ["同じ名前のコマンドが他にもあります"], ["コマンドの名前を入れてください"]])

        let project = ManagedProject(name: "p", path: "/p", commands: [ProjectCommand(name: "dev", command: ""),
                                                                    ProjectCommand(name: "x", command: "y", icon: " ")])
        let warnings = SettingsValidation.warnings(DeckSettings(projects: [project]))
        XCTAssertTrue(warnings.contains("「p」のコマンド「dev」: 実行するコマンドを入れてください"))
        XCTAssertTrue(warnings.contains { $0.hasPrefix("「p」のコマンド「x」: アイコンが空です") })
    }

    func testRunnableHelpAndSymbol() {
        let commands = [ProjectCommand(name: "dev", command: "npm run dev"), ProjectCommand(name: "dev", command: "other"),
                        ProjectCommand(name: "", command: "x"), ProjectCommand(name: "test", command: "make test", icon: "testtube.2")]
        XCTAssertEqual(ProjectCommands.runnable(commands).map(\.command), ["npm run dev", "make test"])
        XCTAssertEqual(ProjectCommands.symbol(for: commands[0]), ProjectCommands.defaultSymbol)
        XCTAssertEqual(ProjectCommands.symbol(for: commands[3]), "testtube.2")
        XCTAssertEqual(ProjectCommands.symbol(for: ProjectCommand(name: "a", command: "b", icon: " ")), ProjectCommands.defaultSymbol)

        let long = ProjectCommand(name: "a", command: (1...9).map { "line\($0)" }.joined(separator: "\n") + "\n")
        XCTAssertEqual(ProjectCommands.help(for: long), "line1\nline2\nline3\nline4\nline5\nline6\n…（ほか 3 行）")
        XCTAssertEqual(ProjectCommands.help(for: commands[0]), "npm run dev")
    }

    func testImportAddsMissingCommandsOnly() throws {
        let incoming = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/p/a", commands: [ProjectCommand(name: "dev", command: "incoming dev"),
                                                               ProjectCommand(name: "test", command: "make test"),
                                                               ProjectCommand(name: "bad", command: " ")]),
            ManagedProject(name: "n", path: "/p/n", commands: [ProjectCommand(name: "dev", command: "npm run dev"),
                                                               ProjectCommand(name: "", command: "x")]),
        ])
        let existing = DeckSettings(projects: [
            ManagedProject(name: "a-local", path: "/p/a", commands: [ProjectCommand(name: " dev", command: "local dev")]),
        ])
        let (settings, summary) = try SettingsImport.merge(try incoming.encoded(), into: existing)
        XCTAssertEqual(settings.projects[0].commands, [ProjectCommand(name: " dev", command: "local dev"),
                                                       ProjectCommand(name: "test", command: "make test")])
        XCTAssertEqual(settings.projects[1].commands, [ProjectCommand(name: "dev", command: "npm run dev")])
        XCTAssertEqual(summary.addedCommands, 1)
        XCTAssertEqual(summary.invalidCommands, 2)
        XCTAssertTrue(summary.message.contains("実行コマンド 1 件（不正 2 件は除外）"), summary.message)
    }
}

final class RoomTabsTests: XCTestCase {
    func testTabMemoryPerRoomWithMoveAndForget() {
        var memory = RoomTabMemory<String>()
        XCTAssertEqual(memory.tab(for: "a"), .claude)
        memory.set(.terminal, for: "a")
        XCTAssertEqual(memory.tab(for: "a"), .terminal)
        XCTAssertEqual(memory.tab(for: "b"), .claude)
        memory.move(from: "a", to: "c")
        XCTAssertEqual(memory.tab(for: "a"), .claude)
        XCTAssertEqual(memory.tab(for: "c"), .terminal)
        memory.forget("c")
        XCTAssertEqual(memory.tab(for: "c"), .claude)
        memory.set(.terminal, for: "d")
        memory.set(.claude, for: "d")
        XCTAssertEqual(memory, RoomTabMemory<String>())
    }

    /// 端末は最後に名乗り出た 1 か所にだけ出し、そこが外れたら残りの最後のものへ戻る。
    func testHostOwnerFollowsLastClaim() {
        var owner = TerminalHostOwner<String>()
        XCTAssertNil(owner.owner)
        owner.claim("main")
        owner.claim("window")
        XCTAssertEqual(owner.owner, "window")
        owner.claim("main")
        XCTAssertEqual(owner.owner, "main")
        XCTAssertEqual(owner.hosts, ["window", "main"])
        owner.release("main")
        XCTAssertEqual(owner.owner, "window")
        owner.release("other")
        XCTAssertEqual(owner.owner, "window")
        owner.release("window")
        XCTAssertNil(owner.owner)
    }
}
