import XCTest
@testable import MonitorKit

final class ProjectLinksTests: XCTestCase {
    func testAcceptsHTTPAndHTTPSWithHost() {
        XCTAssertEqual(ProjectLinks.url(from: "https://example.com/lp")?.absoluteString, "https://example.com/lp")
        XCTAssertEqual(ProjectLinks.url(from: "http://localhost:3000/")?.absoluteString, "http://localhost:3000/")
        XCTAssertEqual(ProjectLinks.url(from: "HTTPS://Example.com/a?b=1#c")?.host, "Example.com")
        XCTAssertEqual(ProjectLinks.url(from: "  https://example.com  ")?.absoluteString, "https://example.com")
    }

    func testRejectsOtherSchemesAndShapes() {
        for bad in ["", "   ", "example.com", "/relative/path", "javascript:alert(1)", "file:///etc/hosts",
                    "mailto:a@example.com", "ftp://example.com", "https://", "https:///path", "https://exa mple.com",
                    "https://example.com/a b", "https://example.com\nhttps://evil.example", "claude-deck://pair?x=1"] {
            XCTAssertNil(ProjectLinks.url(from: bad), bad)
        }
    }

    func testRejectsUserInfo() {
        for bad in ["https://user:pass@example.com", "https://user@example.com/path", "https://:@example.com",
                    "https://@example.com", "http://admin:x@localhost:3000/"] {
            XCTAssertNil(ProjectLinks.url(from: bad), bad)
        }
        // パスやクエリの中の @ は userinfo ではない。
        XCTAssertNotNil(ProjectLinks.url(from: "https://example.com/@user"))
        XCTAssertNotNil(ProjectLinks.url(from: "https://example.com/?to=a@example.com"))
    }

    /// 国際化ドメインは通り、punycode に直した URL になる（`URLComponents` の挙動を固定する）。
    func testInternationalizedDomainIsAccepted() throws {
        let url = try XCTUnwrap(ProjectLinks.url(from: "https://例え.jp/パス?q=日本"))
        XCTAssertEqual(url.absoluteString, "https://xn--r8jz45g.jp/%E3%83%91%E3%82%B9?q=%E6%97%A5%E6%9C%AC")
        XCTAssertEqual(ProjectLinks.url(from: "https://xn--r8jz45g.jp")?.absoluteString, "https://xn--r8jz45g.jp")
        XCTAssertNil(SettingsValidation.linkURLProblem("https://例え.jp"))
    }

    func testOpenableKeepsOrderAndDropsInvalid() {
        let links = [ProjectLink(name: "LP", url: "https://a.example"),
                     ProjectLink(name: "", url: "https://b.example"),
                     ProjectLink(name: "Bad", url: "javascript:x"),
                     ProjectLink(name: "Auth", url: "https://u:p@d.example"),
                     ProjectLink(name: "Docs", url: "http://c.example/docs")]
        XCTAssertEqual(ProjectLinks.openable(links).map(\.name), ["LP", "Docs"])
        XCTAssertEqual(ProjectLinks.openable([]), [])
    }

    func testOpenableDropsLaterDuplicateNames() {
        let links = [ProjectLink(name: "LP", url: "https://a.example"),
                     ProjectLink(name: "Docs", url: "https://b.example"),
                     ProjectLink(name: " LP ", url: "https://c.example"),
                     ProjectLink(name: "lp", url: "https://d.example"),
                     ProjectLink(name: "Docs", url: "https://e.example")]
        // 空白を除いて同じ名前は先のものだけ。大文字小文字は別の名前。
        XCTAssertEqual(ProjectLinks.openable(links).map(\.url), ["https://a.example", "https://b.example", "https://d.example"])
        // 先の同じ名前が開けないものなら、後の開けるものを残す。
        let shadowed = [ProjectLink(name: "LP", url: "nope"), ProjectLink(name: "LP", url: "https://ok.example")]
        XCTAssertEqual(ProjectLinks.openable(shadowed).map(\.url), ["https://ok.example"])
    }

    func testMatchedProjectLinks() {
        let projects = [ManagedProject(name: "a", path: "/p/a", links: [ProjectLink(name: "LP", url: "https://a.example")]),
                        ManagedProject(name: "b", path: "/p/b")]
        XCTAssertEqual(ProjectMatcher.project(for: "/p/a/ios", in: projects).map { ProjectLinks.openable($0.links) }?.count, 1)
        XCTAssertEqual(ProjectMatcher.project(for: "/p/b", in: projects).map { ProjectLinks.openable($0.links) }, [])
        XCTAssertNil(ProjectMatcher.project(for: "/p/c", in: projects))
    }

    func testHelpText() {
        let help = ProjectLinks.help(for: ProjectLink(name: "LP", url: " https://a.example/lp "))
        XCTAssertEqual(help, "LP を開く: https://a.example/lp")
    }

    // MARK: - 種類

    private func kind(_ text: String) -> ProjectLinkKind {
        ProjectLinkKind.suggest(for: URL(string: text)!)
    }

    func testKindSuggestionBilling() {
        XCTAssertEqual(kind("https://console.anthropic.com/settings/billing"), .billing)
        XCTAssertEqual(kind("https://platform.openai.com/usage"), .billing)
        XCTAssertEqual(kind("https://vercel.com/acme/~/settings/billing"), .billing)
        XCTAssertEqual(kind("https://console.cloud.google.com/billing"), .billing)
        XCTAssertEqual(kind("https://dashboard.stripe.com/invoices"), .billing)
        XCTAssertEqual(kind("https://example.com/account/PAYMENT"), .billing)
        XCTAssertEqual(kind("https://billing.example.com/"), .billing)
        XCTAssertEqual(kind("https://example.com/subscription"), .billing)
        XCTAssertEqual(kind("https://example.com/account/payments"), .billing)
        XCTAssertEqual(kind("https://example.com/docs/usage-guide"), .docs)
        XCTAssertEqual(kind("https://example.com/language-usage"), .other)
    }

    func testKindSuggestionStoreDocsDashboard() {
        XCTAssertEqual(kind("https://appstoreconnect.apple.com/apps"), .store)
        XCTAssertEqual(kind("https://apps.apple.com/jp/app/x/id1"), .store)
        XCTAssertEqual(kind("https://play.google.com/console/u/0/developers"), .store)
        XCTAssertEqual(kind("https://docs.example.com/"), .docs)
        XCTAssertEqual(kind("https://example.com/docs/start"), .docs)
        XCTAssertEqual(kind("https://console.anthropic.com/"), .dashboard)
        XCTAssertEqual(kind("https://dashboard.stripe.com/"), .dashboard)
        XCTAssertEqual(kind("https://app.supabase.com/project/x"), .dashboard)
        XCTAssertEqual(kind("https://platform.openai.com/"), .dashboard)
        XCTAssertEqual(kind("https://vercel.com/acme"), .dashboard)
        XCTAssertEqual(kind("https://www.github.com/ShinjoSato/llm-manager"), .dashboard)
        XCTAssertEqual(kind("https://example.com/lp"), .other)
        XCTAssertEqual(kind("http://localhost:3000/"), .other)
    }

    /// 請求 → ストア → ドキュメント → ダッシュボード の順に当てる。
    func testKindSuggestionPrecedence() {
        XCTAssertEqual(kind("https://appstoreconnect.apple.com/agreements/payments"), .billing)
        XCTAssertEqual(kind("https://docs.stripe.com/billing"), .billing)
        XCTAssertEqual(kind("https://console.example.com/docs"), .docs)
    }

    func testKindToSaveKeepsOriginalUnlessChosenOrSuggested() {
        XCTAssertNil(ProjectLinks.kindToSave(selected: .other, touched: false, suggested: false, original: nil))
        XCTAssertEqual(ProjectLinks.kindToSave(selected: .other, touched: false, suggested: false, original: .docs), .docs)
        XCTAssertEqual(ProjectLinks.kindToSave(selected: .billing, touched: false, suggested: true, original: nil), .billing)
        XCTAssertEqual(ProjectLinks.kindToSave(selected: .store, touched: true, suggested: false, original: .docs), .store)
    }

    func testKindLabelsAndSymbols() {
        XCTAssertEqual(ProjectLinkKind.allCases.map(\.rawValue), ["billing", "dashboard", "store", "docs", "other"])
        XCTAssertEqual(ProjectLinkKind.allCases.map(\.label), ["請求", "ダッシュボード", "ストア", "ドキュメント", "その他"])
        XCTAssertEqual(ProjectLinkKind.allCases.map(\.symbol), ["creditcard", "gauge", "storefront", "book", "link"])
        XCTAssertEqual(ProjectLink(name: "a", url: "https://a.example").resolvedKind, .other)
        XCTAssertEqual(ProjectLink(name: "a", url: "https://a.example", kind: .docs).resolvedKind, .docs)
    }

    // MARK: - 名前の提案

    private func suggested(_ text: String) -> String? {
        ProjectLinks.suggestedName(for: URL(string: text)!)
    }

    func testSuggestedNameUsesMainHostLabel() {
        XCTAssertEqual(suggested("https://dashboard.stripe.com/invoices"), "Stripe")
        XCTAssertEqual(suggested("https://console.anthropic.com/"), "Anthropic")
        XCTAssertEqual(suggested("https://appstoreconnect.apple.com/apps"), "Apple")
        XCTAssertEqual(suggested("https://www.figma.com/file/x"), "Figma")
        XCTAssertEqual(suggested("https://GitHub.com/x"), "Github")
        XCTAssertEqual(suggested("https://example.co.jp/"), "Example")
        XCTAssertEqual(suggested("https://shop.example.co.uk/"), "Example")
        XCTAssertEqual(suggested("http://localhost:3000/"), "Localhost")
        XCTAssertEqual(suggested("http://192.168.1.10:3000/"), "192.168.1.10")
    }

    // MARK: - 種類ごとのまとめ

    func testGroupedKeepsKindOrderAndLinkOrder() {
        let links = [ProjectLink(name: "LP", url: "https://a.example"),
                     ProjectLink(name: "Stripe", url: "https://b.example", kind: .billing),
                     ProjectLink(name: "Docs", url: "https://c.example", kind: .docs),
                     ProjectLink(name: "Usage", url: "https://d.example", kind: .billing)]
        let groups = ProjectLinks.grouped(links)
        XCTAssertEqual(groups.map(\.kind), [.billing, .docs, .other])
        XCTAssertEqual(groups.map { $0.links.map(\.name) }, [["Stripe", "Usage"], ["Docs"], ["LP"]])
        XCTAssertEqual(ProjectLinks.grouped([]).count, 0)
        // 種類の無いものだけなら 1 つのまとまり。
        XCTAssertEqual(ProjectLinks.grouped([links[0]]).map(\.kind), [.other])
    }
}

final class LinkTitleTests: XCTestCase {
    func testParsesTitleAndCleansIt() {
        XCTAssertEqual(LinkTitle.parse(html: "<html><head><title>Hello</title></head></html>"), "Hello")
        XCTAssertEqual(LinkTitle.parse(html: "<TITLE lang=\"ja\">\n  Stripe &amp; Co\n  — 請求 </TITLE >"), "Stripe & Co — 請求")
        XCTAssertEqual(LinkTitle.parse(html: "<title>a &lt;b&gt; &quot;c&quot; &#39;d&#39; &#x41;&#66;&nbsp;e &unknown; &amp</title>"),
                       "a <b> \"c\" 'd' AB e &unknown; &amp")
        XCTAssertEqual(LinkTitle.parse(Data("<title>Dash&#x2014;board</title>".utf8)), "Dash—board")
    }

    func testMissingOrEmptyTitleIsNil() {
        XCTAssertNil(LinkTitle.parse(html: "<html><body>no title</body></html>"))
        XCTAssertNil(LinkTitle.parse(html: "<title>   </title>"))
        XCTAssertNil(LinkTitle.parse(html: "<title>unclosed"))
        XCTAssertNil(LinkTitle.parse(Data()))
    }

    /// 先頭 256KB より後ろの `<title>` は見ない。
    func testOnlyReadsHead() {
        let padding = String(repeating: " ", count: LinkTitle.maxBytes)
        XCTAssertNil(LinkTitle.parse(Data((padding + "<title>late</title>").utf8)))
        XCTAssertEqual(LinkTitle.parse(Data(("<title>early</title>" + padding).utf8)), "early")
    }

    func testDecodesTitleCutInsideMultibyteCharacter() {
        let html = "<html><head><title>請求のページ</title><meta name=\"description\" content=\"日本語の説明文です"
        var data = Data(html.utf8)
        // 「す」（3 バイト）の 2 バイト目で切る。
        data.removeLast(1)
        XCTAssertEqual(LinkTitle.parse(data), "請求のページ")
        XCTAssertEqual(LinkTitle.trimmingIncompleteUTF8(Data("abc".utf8)), Data("abc".utf8))
        XCTAssertEqual(LinkTitle.trimmingIncompleteUTF8(Data("あ".utf8)), Data("あ".utf8))
        XCTAssertEqual(LinkTitle.trimmingIncompleteUTF8(Data("あ".utf8).prefix(1)), Data())
    }

    func testDecodesShiftJISWhenDeclared() throws {
        let html = "<html><head><meta charset=\"Shift_JIS\"><title>請求</title><p>説明です"
        let data = try XCTUnwrap(html.data(using: .shiftJIS))
        XCTAssertEqual(LinkTitle.parse(data), "請求")
        // 2 バイト文字の 1 バイト目で切れても読める。
        XCTAssertEqual(LinkTitle.parse(data.dropLast(1)), "請求")
    }

    func testUndecodableDeclaredCharsetGivesNoTitle() throws {
        var data = try XCTUnwrap("<meta charset=\"Shift_JIS\"><title>".data(using: .shiftJIS))
        data.append(contentsOf: [0x81, 0x20, 0x81, 0x20])
        data.append(contentsOf: Data("</title>".utf8))
        XCTAssertNil(LinkTitle.parse(data))
    }

    func testInvalidByteInUTF8DoesNotFallBackToLatin1() {
        var data = Data("<title>請求</title><p>".utf8)
        data.append(0xFF)
        data.append(contentsOf: Data("x".utf8))
        XCTAssertEqual(LinkTitle.parse(data), "請求")
    }
}
