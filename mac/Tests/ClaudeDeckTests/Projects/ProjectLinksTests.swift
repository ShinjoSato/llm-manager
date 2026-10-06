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

    func testOpenableKeepsOrderAndDropsInvalid() {
        let links = [ProjectLink(name: "LP", url: "https://a.example"),
                     ProjectLink(name: "", url: "https://b.example"),
                     ProjectLink(name: "Bad", url: "javascript:x"),
                     ProjectLink(name: "Docs", url: "http://c.example/docs")]
        XCTAssertEqual(ProjectLinks.openable(links).map(\.name), ["LP", "Docs"])
        XCTAssertEqual(ProjectLinks.openable([]), [])
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
