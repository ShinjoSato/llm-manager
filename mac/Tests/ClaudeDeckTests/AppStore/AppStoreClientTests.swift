import CryptoKit
import XCTest
@testable import MonitorKit

/// 見本の応答（架空の値）。
enum AppStoreFixtures {
    static let apps = """
    {"data":[
      {"type":"apps","id":"1000000002","attributes":{"name":"Sample Notes","bundleId":"com.example.notes","sku":"NOTES","primaryLocale":"ja"}},
      {"type":"apps","id":"1000000001","attributes":{"name":"Another Sample","bundleId":"com.example.another","primaryLocale":"en-US"}},
      {"type":"apps","id":"1000000003","attributes":{"name":"Sample Notes Dev","bundleId":"com.example.notes.dev"}}
    ],"links":{"self":"https://api.appstoreconnect.apple.com/v1/apps"}}
    """

    static let versions = """
    {"data":[
      {"type":"appStoreVersions","id":"ver-a","attributes":{"versionString":"1.9","platform":"IOS","appStoreState":"READY_FOR_SALE","appVersionState":"READY_FOR_DISTRIBUTION","createdDate":"2026-01-02T03:04:05.000-08:00"}},
      {"type":"appStoreVersions","id":"ver-b","attributes":{"versionString":"1.10","platform":"IOS","appStoreState":"WAITING_FOR_REVIEW","createdDate":"2026-02-02T03:04:05-08:00"}},
      {"type":"appStoreVersions","id":"ver-c","attributes":{"versionString":"1.8","platform":"IOS","appStoreState":"REPLACED_WITH_NEW_VERSION"}},
      {"type":"appStoreVersions","id":"ver-m","attributes":{"versionString":"1.0","platform":"MAC_OS","appVersionState":"PREPARE_FOR_SUBMISSION"}},
      {"type":"appStoreVersions","id":"","attributes":{"versionString":"9.9"}}
    ]}
    """

    static let appInfos = """
    {"data":[
      {"type":"appInfos","id":"info-live","attributes":{"appStoreState":"READY_FOR_SALE","state":"READY_FOR_DISTRIBUTION"}},
      {"type":"appInfos","id":"info-edit","attributes":{"appStoreState":"PREPARE_FOR_SUBMISSION","state":"PREPARE_FOR_SUBMISSION"}}
    ]}
    """

    static let submissions = """
    {"data":[
      {"type":"reviewSubmissions","id":"sub-1","attributes":{"state":"COMPLETE","platform":"IOS","submittedDate":"2025-12-01T00:00:00Z"}},
      {"type":"reviewSubmissions","id":"sub-2","attributes":{"state":"WAITING_FOR_REVIEW","platform":"IOS","submittedDate":"2026-02-03T00:00:00Z"}},
      {"type":"reviewSubmissions","id":"sub-3","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}
    ]}
    """

    static let versionLocalizations = """
    {"data":[
      {"type":"appStoreVersionLocalizations","id":"loc-en","attributes":{"locale":"en-US","description":"A sample app.","keywords":"notes,sample","promotionalText":null,"whatsNew":"Fixes.","supportUrl":"https://example.com/support","marketingUrl":null}},
      {"type":"appStoreVersionLocalizations","id":"loc-ja","attributes":{"locale":"ja","description":"見本のアプリです。","keywords":"\(String(repeating: "あ", count: 101))","promotionalText":"お知らせ","whatsNew":"修正しました。","supportUrl":"https://example.com/ja/support"}}
    ]}
    """

    static let appInfoLocalizations = """
    {"data":[
      {"type":"appInfoLocalizations","id":"il-ja","attributes":{"locale":"ja","name":"見本ノート","subtitle":"メモを書く"}},
      {"type":"appInfoLocalizations","id":"il-fr","attributes":{"locale":"fr-FR","name":"Notes d'exemple","subtitle":null}}
    ]}
    """
}

final class AppStoreRequestTests: XCTestCase {
    func testEndpointsAreFixedGETsToAppStoreConnect() throws {
        let cases: [(AppStoreRequest.Endpoint, String)] = [
            (.apps, "https://api.appstoreconnect.apple.com/v1/apps?limit=200&fields%5Bapps%5D=name,bundleId,sku,primaryLocale"),
            (.appStoreVersions(appId: "123"), "https://api.appstoreconnect.apple.com/v1/apps/123/appStoreVersions?limit=50"),
            (.versionLocalizations(versionId: "ab-12"),
             "https://api.appstoreconnect.apple.com/v1/appStoreVersions/ab-12/appStoreVersionLocalizations?limit=50&fields%5BappStoreVersionLocalizations%5D=locale,description,keywords,promotionalText,whatsNew,supportUrl,marketingUrl"),
            (.appInfos(appId: "123"), "https://api.appstoreconnect.apple.com/v1/apps/123/appInfos?limit=10"),
            (.appInfoLocalizations(appInfoId: "cd-34"),
             "https://api.appstoreconnect.apple.com/v1/appInfos/cd-34/appInfoLocalizations?limit=50&fields%5BappInfoLocalizations%5D=locale,name,subtitle"),
            (.reviewSubmissions(appId: "123"), "https://api.appstoreconnect.apple.com/v1/reviewSubmissions?filter%5Bapp%5D=123&limit=20"),
        ]
        for (endpoint, expected) in cases {
            let request = try XCTUnwrap(AppStoreRequest.make(endpoint))
            XCTAssertEqual(request.url.absoluteString, expected)
            let urlRequest = request.urlRequest(token: "t")
            XCTAssertEqual(urlRequest.httpMethod, "GET")
            XCTAssertNil(urlRequest.httpBody)
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        }
    }

    func testIDsCannotRewriteThePath() {
        for bad in ["", "12a", "../1", "1/2", "1?x=1", "１２３", String(repeating: "1", count: 21)] {
            XCTAssertNil(AppStoreRequest.make(.appStoreVersions(appId: bad)), bad)
            XCTAssertNil(AppStoreRequest.make(.reviewSubmissions(appId: bad)), bad)
        }
        for bad in ["", "a/b", "a..b", "a b", "a%2Fb", String(repeating: "a", count: 65)] {
            XCTAssertNil(AppStoreRequest.make(.versionLocalizations(versionId: bad)), bad)
            XCTAssertNil(AppStoreRequest.make(.appInfoLocalizations(appInfoId: bad)), bad)
        }
    }

    func testNextLinkMustStayOnTheAPI() {
        XCTAssertNotNil(AppStoreRequest.next("https://api.appstoreconnect.apple.com/v1/apps?cursor=AB&limit=200"))
        for bad in ["http://api.appstoreconnect.apple.com/v1/apps", "https://example.com/v1/apps",
                    "https://api.appstoreconnect.apple.com.example.com/v1/apps", "https://user:pw@api.appstoreconnect.apple.com/v1/apps",
                    "https://api.appstoreconnect.apple.com:8443/v1/apps", "https://api.appstoreconnect.apple.com/v2/apps",
                    "https://api.appstoreconnect.apple.com/v1/../x", "/v1/apps", "not a url"] {
            XCTAssertNil(AppStoreRequest.next(bad), bad)
        }
    }
}

final class AppStoreResponseTests: XCTestCase {
    func testParsesAppsAndSkipsUnknownAttributes() throws {
        let page = try AppStoreResponse.apps(Data(AppStoreFixtures.apps.utf8))
        XCTAssertEqual(page.items.map(\.id), ["1000000002", "1000000001", "1000000003"])
        XCTAssertEqual(page.items[0], AppStoreApp(id: "1000000002", name: "Sample Notes", bundleId: "com.example.notes", sku: "NOTES", primaryLocale: "ja"))
        XCTAssertNil(page.next)
        XCTAssertThrowsError(try AppStoreResponse.apps(Data("<html>".utf8)))
        XCTAssertThrowsError(try AppStoreResponse.apps(Data(#"{"errors":[]}"#.utf8)))
    }

    func testParsesVersionsPreferringNewStateName() throws {
        let versions = try AppStoreResponse.versions(Data(AppStoreFixtures.versions.utf8)).items
        XCTAssertEqual(versions.map(\.id), ["ver-a", "ver-b", "ver-c", "ver-m"])
        XCTAssertEqual(versions[0].state, "READY_FOR_DISTRIBUTION")
        XCTAssertEqual(versions[1].state, "WAITING_FOR_REVIEW")
        XCTAssertNotNil(versions[0].createdDate)
        XCTAssertNotNil(versions[1].createdDate)
        XCTAssertTrue(versions[0].isLive)
    }

    func testOverviewPicksLatestAndLivePerPlatform() throws {
        let overview = AppStoreAppOverview(
            versions: try AppStoreResponse.versions(Data(AppStoreFixtures.versions.utf8)).items,
            appInfos: try AppStoreResponse.appInfos(Data(AppStoreFixtures.appInfos.utf8)).items,
            submissions: try AppStoreResponse.reviewSubmissions(Data(AppStoreFixtures.submissions.utf8)).items)
        let platforms = overview.platforms
        XCTAssertEqual(platforms.map(\.platform), ["IOS", "MAC_OS"])
        // 1.10 は 1.9 より新しい。
        XCTAssertEqual(platforms[0].latest.versionString, "1.10")
        XCTAssertEqual(platforms[0].live?.versionString, "1.9")
        XCTAssertEqual(platforms[0].metadataVersions.map(\.id), ["ver-b", "ver-a"])
        XCTAssertEqual(platforms[1].latest.id, "ver-m")
        XCTAssertNil(platforms[1].live)
        // 下書き（未提出）を先に、あとは提出の新しい順。
        XCTAssertEqual(overview.submissions.map(\.id), ["sub-3", "sub-2", "sub-1"])
        // 公開中の版には公開中の情報、編集中の版には編集中の情報。
        XCTAssertEqual(AppStoreVersions.appInfo(for: platforms[0].latest, in: overview.appInfos)?.id, "info-edit")
        XCTAssertEqual(AppStoreVersions.appInfo(for: platforms[0].live!, in: overview.appInfos)?.id, "info-live")
        XCTAssertEqual(AppStoreVersions.appInfo(for: platforms[0].latest, in: [overview.appInfos[0]])?.id, "info-live")
        XCTAssertNil(AppStoreVersions.appInfo(for: platforms[0].latest, in: []))
    }

    func testLatestIsLiveShowsNoSeparateLive() {
        let summaries = AppStoreVersions.summaries([
            AppStoreVersion(id: "1", versionString: "2.0", platform: "IOS", state: "READY_FOR_SALE"),
            AppStoreVersion(id: "2", versionString: "1.0", platform: "IOS", state: "REPLACED_WITH_NEW_VERSION"),
        ])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertNil(summaries[0].live)
        XCTAssertEqual(summaries[0].metadataVersions.map(\.id), ["1"])
    }

    func testVersionCompare() {
        XCTAssertEqual(AppStoreVersions.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(AppStoreVersions.compare("1.0", "1"), .orderedSame)
        XCTAssertEqual(AppStoreVersions.compare("2.0.1", "2.0"), .orderedDescending)
        XCTAssertEqual(AppStoreVersions.compare("1.0b2", "1.0b10"), .orderedAscending)
    }

    func testMetadataMergesLocalesWithLimits() throws {
        let version = try AppStoreResponse.versionLocalizations(Data(AppStoreFixtures.versionLocalizations.utf8)).items
        let info = try AppStoreResponse.appInfoLocalizations(Data(AppStoreFixtures.appInfoLocalizations.utf8)).items
        let merged = AppStoreLocaleMetadata.merge(version: version, info: info, primaryLocale: "ja")
        XCTAssertEqual(merged.map(\.locale), ["ja", "en-US", "fr-FR"])
        let ja = merged[0]
        XCTAssertEqual(ja.value(.name), "見本ノート")
        XCTAssertEqual(ja.value(.subtitle), "メモを書く")
        XCTAssertEqual(ja.value(.whatsNew), "修正しました。")
        XCTAssertEqual(ja.overLimitFields, [.keywords])
        XCTAssertNil(merged[1].value(.promotionalText))
        XCTAssertNil(merged[1].value(.name))
        XCTAssertEqual(merged[2].value(.name), "Notes d'exemple")
        XCTAssertNil(merged[2].value(.description))
    }

    func testFieldLimitsAndCounting() {
        XCTAssertEqual(AppStoreMetadataField.allCases.map(\.limit), [30, 30, 4000, 100, 170, 4000, nil, nil])
        XCTAssertEqual(AppStoreMetadataField.count("あいう"), 3)
        XCTAssertEqual(AppStoreMetadataField.count(nil), 0)
        XCTAssertFalse(AppStoreMetadataField.name.isOver(String(repeating: "a", count: 30)))
        XCTAssertTrue(AppStoreMetadataField.name.isOver(String(repeating: "a", count: 31)))
        XCTAssertTrue(AppStoreMetadataField.promotionalText.isOver(String(repeating: "x", count: 171)))
        XCTAssertFalse(AppStoreMetadataField.supportUrl.isOver(String(repeating: "x", count: 5000)))
    }

    func testErrorSummary() {
        let body = Data(#"{"errors":[{"status":"403","code":"FORBIDDEN","title":"Not allowed","detail":"Role is not enough"}]}"#.utf8)
        XCTAssertEqual(AppStoreResponse.errorSummary(body), "Not allowed: Role is not enough")
        XCTAssertNil(AppStoreResponse.errorSummary(Data("oops".utf8)))
    }
}

final class AppStoreStatesTests: XCTestCase {
    func testVersionStatesInJapanese() {
        XCTAssertEqual(AppStoreStates.versionLabel("PREPARE_FOR_SUBMISSION"), "提出準備中")
        XCTAssertEqual(AppStoreStates.versionLabel("WAITING_FOR_REVIEW"), "審査待ち")
        XCTAssertEqual(AppStoreStates.versionLabel("IN_REVIEW"), "審査中")
        XCTAssertEqual(AppStoreStates.versionLabel("REJECTED"), "リジェクト")
        XCTAssertEqual(AppStoreStates.versionLabel("METADATA_REJECTED"), "メタデータのリジェクト")
        XCTAssertEqual(AppStoreStates.versionLabel("PENDING_DEVELOPER_RELEASE"), "公開待ち（手動で公開）")
        XCTAssertEqual(AppStoreStates.versionLabel("READY_FOR_SALE"), "公開中")
        XCTAssertEqual(AppStoreStates.versionLabel("READY_FOR_DISTRIBUTION"), "公開中")
        XCTAssertEqual(AppStoreStates.versionLabel("DEVELOPER_REJECTED"), "取り下げ（開発者）")
        XCTAssertEqual(AppStoreStates.versionLabel(nil), "不明")
    }

    func testUnknownValuesAreShownAsIs() {
        XCTAssertEqual(AppStoreStates.versionLabel("SOMETHING_NEW"), "SOMETHING_NEW")
        XCTAssertEqual(AppStoreStates.submissionLabel("SOMETHING_NEW"), "SOMETHING_NEW")
        XCTAssertEqual(AppStoreStates.versionTone("SOMETHING_NEW"), .unknown)
        XCTAssertEqual(AppStoreStates.platformLabel("WATCH_OS"), "WATCH_OS")
    }

    func testSubmissionStatesInJapanese() {
        XCTAssertEqual(AppStoreStates.submissionLabel("READY_FOR_REVIEW"), "提出前（下書き）")
        XCTAssertEqual(AppStoreStates.submissionLabel("WAITING_FOR_REVIEW"), "審査待ち")
        XCTAssertEqual(AppStoreStates.submissionLabel("IN_REVIEW"), "審査中")
        XCTAssertEqual(AppStoreStates.submissionLabel("UNRESOLVED_ISSUES"), "未解決の問題あり")
        XCTAssertEqual(AppStoreStates.submissionLabel("COMPLETE"), "完了")
    }

    func testTones() {
        XCTAssertEqual(AppStoreStates.versionTone("PREPARE_FOR_SUBMISSION"), .editing)
        XCTAssertEqual(AppStoreStates.versionTone("WAITING_FOR_REVIEW"), .waiting)
        XCTAssertEqual(AppStoreStates.versionTone("IN_REVIEW"), .inReview)
        XCTAssertEqual(AppStoreStates.versionTone("METADATA_REJECTED"), .rejected)
        XCTAssertEqual(AppStoreStates.versionTone("PENDING_DEVELOPER_RELEASE"), .pendingRelease)
        XCTAssertEqual(AppStoreStates.versionTone("READY_FOR_SALE"), .live)
        XCTAssertEqual(AppStoreStates.submissionTone("UNRESOLVED_ISSUES"), .rejected)
        // 版の状態はすべて名前がある（原文のまま出るのは知らない値だけ）。
        for raw in AppStoreStates.versionLabels.keys { XCTAssertNotEqual(AppStoreStates.versionTone(raw), .unknown, raw) }
        for raw in AppStoreStates.submissionLabels.keys { XCTAssertNotEqual(AppStoreStates.submissionTone(raw), .unknown, raw) }
    }
}

final class AppStoreCacheTests: XCTestCase {
    func testEntriesExpireAfterLifetime() {
        var cache = AppStoreCache<String, Int>(lifetime: 600)
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(cache.fresh("a", now: start))
        cache.store(1, for: "a", at: start)
        XCTAssertEqual(cache.fresh("a", now: start.addingTimeInterval(599))?.value, 1)
        XCTAssertEqual(cache.fresh("a", now: start.addingTimeInterval(599))?.fetchedAt, start)
        XCTAssertNil(cache.fresh("a", now: start.addingTimeInterval(600)))
        // 時計が戻った時も古い値を新しいとみなさない。
        XCTAssertNil(cache.fresh("a", now: start.addingTimeInterval(-1)))
        cache.store(2, for: "b", at: start)
        cache.removeAll()
        XCTAssertNil(cache.fresh("b", now: start))
        XCTAssertEqual(AppStoreCache<String, Int>.defaultLifetime, 600)
    }
}

/// 送った要求を覚え、決めた応答を返す偽の通信。
final class FakeAppStoreTransport: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
    }

    private let lock = NSLock()
    private var routes: [(match: String, reply: Reply)] = []
    private(set) var requests: [URLRequest] = []

    func on(_ pathContains: String, status: Int = 200, _ body: String) {
        lock.withLock { routes.append((pathContains, Reply(status: status, body: body))) }
    }

    var sent: [URLRequest] { lock.withLock { requests } }

    var transport: AppStoreClient.Transport {
        { [self] request in
            let reply: Reply = lock.withLock {
                requests.append(request)
                let url = request.url?.absoluteString ?? ""
                return routes.last(where: { url.contains($0.match) })?.reply ?? Reply(status: 404, body: "{}")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            return (Data(reply.body.utf8), response)
        }
    }
}

final class AppStoreClientTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()

    private func client(_ fake: FakeAppStoreTransport,
                        credentials: Result<AppStoreCredentials, AppStoreCredentialProblem>? = nil) -> AppStoreClient {
        let creds = credentials ?? .success(AppStoreCredentials(keyID: "KID", issuerID: "ISS", privateKey: key))
        return AppStoreClient(transport: fake.transport, credentials: { creds })
    }

    func testOverviewSendsOnlySignedGETs() async throws {
        let fake = FakeAppStoreTransport()
        fake.on("/appStoreVersions?", AppStoreFixtures.versions)
        fake.on("/appInfos?", AppStoreFixtures.appInfos)
        fake.on("/reviewSubmissions?", AppStoreFixtures.submissions)
        let overview = try await client(fake).overview(appId: "1000000002")
        XCTAssertEqual(overview.platforms.first?.latest.versionString, "1.10")
        XCTAssertEqual(fake.sent.count, 3)
        for request in fake.sent {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "api.appstoreconnect.apple.com")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertNil(request.httpBody)
            let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(auth.hasPrefix("Bearer "))
            // 同じトークンを使い回す（要求ごとに作り直さない）。
            XCTAssertEqual(auth, fake.sent[0].value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testMetadataReadsVersionAndInfoLocalizations() async throws {
        let fake = FakeAppStoreTransport()
        fake.on("/appStoreVersionLocalizations?", AppStoreFixtures.versionLocalizations)
        fake.on("/appInfoLocalizations?", AppStoreFixtures.appInfoLocalizations)
        let list = try await client(fake).metadata(versionId: "ver-b", appInfoId: "info-edit", primaryLocale: "en-US")
        XCTAssertEqual(list.map(\.locale), ["en-US", "fr-FR", "ja"])
        XCTAssertEqual(fake.sent.map { $0.url?.path ?? "" },
                       ["/v1/appStoreVersions/ver-b/appStoreVersionLocalizations", "/v1/appInfos/info-edit/appInfoLocalizations"])
    }

    func testPagingFollowsOnlyLinksOnTheAPI() async throws {
        let fake = FakeAppStoreTransport()
        fake.on("/v1/apps?", """
        {"data":[{"type":"apps","id":"1","attributes":{"name":"B","bundleId":"com.example.b"}}],
         "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=Mg&limit=200"}}
        """)
        fake.on("cursor=Mg", """
        {"data":[{"type":"apps","id":"2","attributes":{"name":"A","bundleId":"com.example.a"}}],
         "links":{"next":"https://example.com/v1/apps?cursor=Mw"}}
        """)
        let apps = try await client(fake).apps()
        XCTAssertEqual(apps.map(\.id), ["2", "1"])
        XCTAssertEqual(fake.sent.count, 2)
    }

    func testFailuresAreNotRetried() async {
        for (status, expected) in [(401, AppStoreFailure.unauthorized), (404, .notFound), (429, .rateLimited), (503, .server(503))] {
            let fake = FakeAppStoreTransport()
            fake.on("/v1/apps", status: status, #"{"errors":[{"title":"t"}]}"#)
            do throws(AppStoreFailure) {
                _ = try await client(fake).apps()
                XCTFail("失敗するはず")
            } catch {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(fake.sent.count, 1, "\(status)")
        }
        let fake = FakeAppStoreTransport()
        fake.on("/v1/apps", status: 403, #"{"errors":[{"title":"Forbidden","detail":"no access"}]}"#)
        do throws(AppStoreFailure) {
            _ = try await client(fake).apps()
        } catch {
            XCTAssertEqual(error, .forbidden("Forbidden: no access"))
        }
    }

    func testMissingCredentialsSendNothing() async {
        let fake = FakeAppStoreTransport()
        do throws(AppStoreFailure) {
            _ = try await client(fake, credentials: .failure(.missingKeyID)).apps()
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .credentials(.missingKeyID))
        }
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testInvalidAppIDSendsNothing() async {
        let fake = FakeAppStoreTransport()
        do throws(AppStoreFailure) {
            _ = try await client(fake).overview(appId: "../apps")
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .invalidRequest)
        }
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testBrokenBodyIsBadResponse() async {
        let fake = FakeAppStoreTransport()
        fake.on("/v1/apps", "not json")
        do throws(AppStoreFailure) {
            _ = try await client(fake).apps()
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .badResponse)
        }
    }

    /// 案内の文言にトークンや鍵の ID を混ぜない。
    func testMessagesDoNotContainSecrets() {
        let failures: [AppStoreFailure] = [.unauthorized, .forbidden("x"), .notFound, .rateLimited, .server(500), .http(400, "y"),
                                           .network("z"), .badResponse, .invalidRequest, .credentials(.missingKeyID)]
        for failure in failures {
            XCTAssertFalse(failure.message.contains("KID"))
            XCTAssertFalse(failure.message.contains("Bearer"))
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertTrue(AppStoreFailure.rateLimited.message.contains("再読み込み"))
    }
}
