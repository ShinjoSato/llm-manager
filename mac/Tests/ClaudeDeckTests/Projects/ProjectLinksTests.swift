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
}
