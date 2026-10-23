import XCTest
@testable import MonitorKit

final class AppStoreSettingsTests: XCTestCase {
    private func decode(_ appStore: String) throws -> ManagedProject {
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active"\#(appStore)}]}"#
        guard case .loaded(let settings) = SettingsFile.decode(Data(json.utf8)) else {
            XCTFail("読めるはず: \(appStore)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings.projects[0]
    }

    func testAppStoreIsOptionalAndRoundTrips() throws {
        XCTAssertEqual(try decode("").appStoreApps, [])
        let project = try decode(#","appStore":[{"appId":"123","name":"本番"},{"appId":456,"name":"検証用"}]"#)
        XCTAssertEqual(project.appStoreApps, [AppStoreAppLink(appId: "123", name: "本番"), AppStoreAppLink(appId: "456", name: "検証用")])

        var settings = DeckSettings(projects: [project, ManagedProject(name: "b", path: "/b")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.encoded()) as? [String: Any])
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        let apps = try XCTUnwrap(projects[0]["appStore"] as? [[String: Any]])
        XCTAssertEqual(apps.map { $0["appId"] as? String }, ["123", "456"])
        XCTAssertEqual(apps[0].keys.sorted(), ["appId", "name"])
        // 無いプロジェクトには書かない。
        XCTAssertNil(projects[1]["appStore"])
        XCTAssertEqual(object["version"] as? Int, 1)

        settings.projects[0].appStoreApps = []
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.encoded()) as? [String: Any])
        XCTAssertNil((cleared["projects"] as? [[String: Any]])?.first?["appStore"])
    }

    /// `site` と同じく、形の違う `appStore` は無視して警告を出し、ファイル全体は読める。
    func testMalformedAppStoreIsIgnoredWithWarning() throws {
        for bad in [#","appStore":"123""#, #","appStore":[{"name":"x"}]"#, #","appStore":{"appId":"1"}"#] {
            let project = try decode(bad)
            XCTAssertEqual(project.appStoreApps, [], bad)
            XCTAssertTrue(project.ignoredAppStore.isSet, bad)
            let warnings = SettingsValidation.warnings(DeckSettings(projects: [project]))
            XCTAssertTrue(warnings.contains { $0.contains("App Store") && $0.contains("無視しました") }, bad)
        }
        XCTAssertFalse(try decode(#","appStore":null"#).ignoredAppStore.isSet)
    }

    func testRowProblems() {
        let rows = [AppStoreAppLink(appId: "123", name: "本番"), AppStoreAppLink(appId: "12a", name: " "),
                    AppStoreAppLink(appId: "123", name: "重複")]
        let problems = SettingsValidation.appStoreRowProblems(rows)
        XCTAssertEqual(problems[0], [])
        XCTAssertEqual(problems[1].count, 2)
        XCTAssertEqual(problems[2], ["同じ appId のアプリが他にもあります"])
        let warnings = SettingsValidation.warnings(DeckSettings(projects: [ManagedProject(name: "p", path: "/p", appStoreApps: rows)]))
        XCTAssertEqual(warnings.filter { $0.contains("App Store") }.count, 3)
    }

    func testImportFillsAppStoreOnlyWhenEmpty() throws {
        let incoming = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/p/a", appStoreApps: [AppStoreAppLink(appId: "1", name: "in")]),
            ManagedProject(name: "b", path: "/p/b", appStoreApps: [AppStoreAppLink(appId: "2", name: "in")]),
        ])
        let existing = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/p/a"),
            ManagedProject(name: "b", path: "/p/b", appStoreApps: [AppStoreAppLink(appId: "3", name: "mine")]),
        ])
        let (settings, summary) = try SettingsImport.merge(try incoming.encoded(), into: existing)
        XCTAssertEqual(settings.projects[0].appStoreApps, [AppStoreAppLink(appId: "1", name: "in")])
        XCTAssertEqual(settings.projects[1].appStoreApps, [AppStoreAppLink(appId: "3", name: "mine")])
        XCTAssertEqual(summary.skipped, 1)
    }

    @MainActor
    func testScheduledAppStoreEditIsSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asc-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = SettingsFile(url: dir.appendingPathComponent("settings.json"))
        let store = SettingsStore(file: file)
        store.add(paths: ["/tmp/asc-project"])
        let id = try XCTUnwrap(store.projects.first?.id)
        store.scheduleProject(id: id, field: "appStore", \.appStoreApps, [AppStoreAppLink(appId: "77", name: "本番")])
        store.flushPending(force: true)
        guard case .loaded(let saved) = file.load() else { return XCTFail() }
        XCTAssertEqual(saved.projects.first?.appStoreApps, [AppStoreAppLink(appId: "77", name: "本番")])
    }
}
