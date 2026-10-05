import XCTest
@testable import MonitorKit

final class ProjectMatcherTests: XCTestCase {
    private func project(_ name: String, _ path: String) -> ManagedProject {
        ManagedProject(name: name, path: path, github: GitHubLink(owner: "o", repo: name))
    }

    func testExactAndSubdirectoryMatch() {
        let projects = [project("a", "/Users/me/a"), project("b", "/Users/me/b")]
        XCTAssertEqual(ProjectMatcher.project(for: "/Users/me/a", in: projects)?.name, "a")
        XCTAssertEqual(ProjectMatcher.project(for: "/Users/me/b/ios/App", in: projects)?.name, "b")
        XCTAssertNil(ProjectMatcher.project(for: "/Users/me", in: projects))
        XCTAssertNil(ProjectMatcher.project(for: "/Users/me/c", in: projects))
    }

    func testDoesNotMatchSiblingWithSamePrefix() {
        let projects = [project("ab", "/a/b")]
        XCTAssertNil(ProjectMatcher.project(for: "/a/bc", in: projects))
        XCTAssertNil(ProjectMatcher.project(for: "/a/bc/d", in: projects))
        XCTAssertEqual(ProjectMatcher.project(for: "/a/b/c", in: projects)?.name, "ab")
    }

    func testDeepestPathWins() {
        let projects = [project("root", "/a"), project("deep", "/a/b/c"), project("mid", "/a/b")]
        XCTAssertEqual(ProjectMatcher.project(for: "/a/b/c/d", in: projects)?.name, "deep")
        XCTAssertEqual(ProjectMatcher.project(for: "/a/b/x", in: projects)?.name, "mid")
        XCTAssertEqual(ProjectMatcher.project(for: "/a/z", in: projects)?.name, "root")
    }

    func testTrailingSlashesAndDotsAreNormalized() {
        let projects = [project("a", "/x/y/")]
        XCTAssertEqual(ProjectMatcher.project(for: "/x/y", in: projects)?.name, "a")
        XCTAssertEqual(ProjectMatcher.project(for: "/x/y//", in: projects)?.name, "a")
        XCTAssertEqual(ProjectMatcher.project(for: "/x/z/../y/./sub/", in: projects)?.name, "a")
        XCTAssertEqual(ProjectMatcher.project(for: "/x/y", in: [project("b", "/x/./y/sub/..")])?.name, "b")
    }

    func testRelativeOrEmptyPathsDoNotMatch() {
        let projects = [project("a", "/x"), project("rel", "x/y")]
        XCTAssertNil(ProjectMatcher.project(for: "", in: projects))
        XCTAssertNil(ProjectMatcher.project(for: "x/y", in: projects))
        XCTAssertEqual(ProjectMatcher.project(for: "/x/y", in: projects)?.name, "a")
    }

    func testRootProjectMatchesEverythingButLosesToDeeper() {
        let projects = [project("root", "/"), project("a", "/a")]
        XCTAssertEqual(ProjectMatcher.project(for: "/b", in: projects)?.name, "root")
        XCTAssertEqual(ProjectMatcher.project(for: "/a/b", in: projects)?.name, "a")
    }
}

final class GitHubURLsTests: XCTestCase {
    func testBoardURLByOwnerKind() {
        XCTAssertEqual(GitHubURLs.board(owner: "ShinjoSato", number: 8, kind: .user)?.absoluteString,
                       "https://github.com/users/ShinjoSato/projects/8")
        XCTAssertEqual(GitHubURLs.board(owner: "my-org", number: 12, kind: .organization)?.absoluteString,
                       "https://github.com/orgs/my-org/projects/12")
    }

    func testRepositoryURL() {
        XCTAssertEqual(GitHubURLs.repository(owner: "ShinjoSato", repo: "llm-manager")?.absoluteString,
                       "https://github.com/ShinjoSato/llm-manager")
        XCTAssertEqual(GitHubURLs.repository(owner: "a", repo: "x.y_z-1")?.absoluteString, "https://github.com/a/x.y_z-1")
    }

    func testRejectsInvalidValues() {
        XCTAssertNil(GitHubURLs.board(owner: "a/b", number: 1, kind: .user))
        XCTAssertNil(GitHubURLs.board(owner: "a", number: 0, kind: .user))
        XCTAssertNil(GitHubURLs.board(owner: "", number: 1, kind: .user))
        XCTAssertNil(GitHubURLs.repository(owner: "a", repo: "../evil"))
        XCTAssertNil(GitHubURLs.repository(owner: "a", repo: ".."))
        XCTAssertNil(GitHubURLs.repository(owner: "a", repo: "x?y=1"))
        XCTAssertNil(GitHubURLs.repository(owner: "a b", repo: "x"))
        XCTAssertNil(GitHubURLs.userAPI(owner: "a/../b"))
    }

    func testSegmentEncodesSeparators() {
        XCTAssertEqual(GitHubURLs.segment("a/b?c#d"), "a%2Fb%3Fc%23d")
    }

    func testUserAPIURL() {
        XCTAssertEqual(GitHubURLs.userAPI(owner: "ShinjoSato")?.absoluteString, "https://api.github.com/users/ShinjoSato")
    }

    func testOwnerKindFromResponse() {
        let user = Data(#"{"login":"a","type":"User"}"#.utf8)
        let org = Data(#"{"login":"b","type":"Organization"}"#.utf8)
        XCTAssertEqual(GitHubURLs.ownerKind(status: 200, body: user), .user)
        XCTAssertEqual(GitHubURLs.ownerKind(status: 200, body: org), .organization)
        XCTAssertNil(GitHubURLs.ownerKind(status: 404, body: org))
        XCTAssertNil(GitHubURLs.ownerKind(status: 403, body: Data(#"{"message":"rate limit"}"#.utf8)))
        XCTAssertNil(GitHubURLs.ownerKind(status: 200, body: Data("not json".utf8)))
        XCTAssertNil(GitHubURLs.ownerKind(status: 200, body: Data(#"{"type":"Bot"}"#.utf8)))
    }

    func testDestinations() {
        XCTAssertEqual(GitHubDestination.all(for: GitHubLink(owner: "o", repo: "r", projectNumber: 3)),
                       [.board(owner: "o", number: 3), .repository(owner: "o", repo: "r")])
        XCTAssertEqual(GitHubDestination.all(for: GitHubLink(owner: "o", repo: "r")), [.repository(owner: "o", repo: "r")])
        XCTAssertEqual(GitHubDestination.all(for: GitHubLink(owner: "o", projectNumber: 3)), [.board(owner: "o", number: 3)])
        XCTAssertEqual(GitHubDestination.all(for: GitHubLink(owner: "o/x", repo: "r", projectNumber: 3)), [])
        XCTAssertEqual(GitHubDestination.all(for: GitHubLink(owner: "o", repo: "bad/repo", projectNumber: 0)), [])
    }

    func testDestinationURLFallsBackToUsersWhenKindUnknown() {
        let board = GitHubDestination.board(owner: "o", number: 5)
        XCTAssertEqual(board.url(ownerKind: nil)?.absoluteString, "https://github.com/users/o/projects/5")
        XCTAssertEqual(board.url(ownerKind: .organization)?.absoluteString, "https://github.com/orgs/o/projects/5")
        XCTAssertEqual(GitHubDestination.repository(owner: "o", repo: "r").url(ownerKind: nil)?.absoluteString,
                       "https://github.com/o/r")
        XCTAssertTrue(board.help.contains("#5"))
        XCTAssertTrue(GitHubDestination.repository(owner: "o", repo: "r").help.contains("o/r"))
    }
}

@MainActor
final class GitHubOwnerKindResolverTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) -> Int { lock.withLock { urls.append(url); return urls.count } }
        var all: [URL] { lock.withLock { urls } }
    }

    func testCachesPerOwnerCaseInsensitively() async {
        let calls = Calls()
        let resolver = GitHubOwnerKindResolver { url in
            _ = calls.add(url)
            return (200, Data(#"{"type":"Organization"}"#.utf8))
        }
        let first = await resolver.kind(of: "MyOrg")
        let second = await resolver.kind(of: "myorg")
        XCTAssertEqual(first, .organization)
        XCTAssertEqual(second, .organization)
        XCTAssertEqual(resolver.cachedKind(of: "MYORG"), .organization)
        XCTAssertEqual(calls.all.map(\.absoluteString), ["https://api.github.com/users/MyOrg"])
    }

    func testFailureIsNotCached() async {
        let calls = Calls()
        let resolver = GitHubOwnerKindResolver { url in
            if calls.add(url) == 1 { throw URLError(.notConnectedToInternet) }
            return (200, Data(#"{"type":"User"}"#.utf8))
        }
        let failed = await resolver.kind(of: "me")
        XCTAssertNil(failed)
        XCTAssertNil(resolver.cachedKind(of: "me"))
        let retried = await resolver.kind(of: "me")
        XCTAssertEqual(retried, .user)
        XCTAssertEqual(calls.all.count, 2)
    }

    func testRateLimitedResponseGivesNil() async {
        let resolver = GitHubOwnerKindResolver { _ in (403, Data(#"{"message":"API rate limit exceeded"}"#.utf8)) }
        let kind = await resolver.kind(of: "me")
        XCTAssertNil(kind)
    }

    func testTimesOutEvenIfFetchIgnoresCancellation() async {
        let resolver = GitHubOwnerKindResolver(timeout: .milliseconds(100)) { _ in
            Thread.sleep(forTimeInterval: 1)
            return (200, Data(#"{"type":"Organization"}"#.utf8))
        }
        let start = Date()
        let kind = await resolver.kind(of: "slow")
        XCTAssertNil(kind)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }

    func testInvalidOwnerDoesNotFetch() async {
        let calls = Calls()
        let resolver = GitHubOwnerKindResolver { url in
            _ = calls.add(url)
            return (200, Data(#"{"type":"User"}"#.utf8))
        }
        let kind = await resolver.kind(of: "../etc")
        XCTAssertNil(kind)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testDefaultTimeoutIsThreeSeconds() {
        XCTAssertEqual(GitHubOwnerKindResolver.defaultTimeout, .seconds(3))
    }
}
