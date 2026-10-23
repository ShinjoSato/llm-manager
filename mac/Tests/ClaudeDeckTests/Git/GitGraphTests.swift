import XCTest
@testable import MonitorKit

private func oid(_ seed: String) -> String {
    let hex = Array(seed.utf8).map { String(format: "%02x", $0) }.joined()
    return String((hex + String(repeating: "0", count: 40)).prefix(40))
}

private func commit(_ name: String, _ parents: [String] = []) -> GitCommit {
    GitCommit(hash: oid(name), parents: parents.map(oid), subject: name)
}

private func logRecord(_ commit: GitCommit) -> Data {
    let fields = [commit.hash, commit.parents.joined(separator: " "), commit.authorName, commit.authorEmail,
                  String(Int(commit.authorDate.timeIntervalSince1970)), commit.subject]
    return Data((fields.joined(separator: "\0") + "\0").utf8)
}

final class GitLogParserTests: XCTestCase {
    func testParsesFieldsWithSeparatorsAndEmoji() {
        let subject = "fix: 区切り\u{1f}\u{1e} と %x00 と タブ\tと 🚀 絵文字"
        let a = GitCommit(hash: oid("a"), parents: [], authorName: "山田 太郎", authorEmail: "t@example.com",
                          authorDate: Date(timeIntervalSince1970: 1_700_000_000), subject: subject)
        let b = GitCommit(hash: oid("b"), parents: [oid("a"), oid("c")], authorName: "", authorEmail: "",
                          authorDate: Date(timeIntervalSince1970: 1_700_000_100), subject: "")
        let parsed = GitLogParser.parseLog(logRecord(b) + logRecord(a))
        XCTAssertEqual(parsed, [b, a])
        XCTAssertTrue(parsed[0].isMerge)
        XCTAssertEqual(parsed[1].parents, [])
        XCTAssertEqual(parsed[1].shortHash, String(oid("a").prefix(7)))
    }

    func testDropsTruncatedLastRecordAndStopsOnMisalignment() {
        let a = commit("a"), b = commit("b", ["a"])
        var data = logRecord(b) + logRecord(a)
        data.removeLast(3)
        XCTAssertEqual(GitLogParser.parseLog(data), [b])
        XCTAssertEqual(GitLogParser.parseLog(Data("not-a-hash\0\0x\0y\0z\0s\0".utf8)), [])
        XCTAssertEqual(GitLogParser.parseLog(Data()), [])
    }

    func testParsesRefsAndSkipsSymbolicOnes() {
        let lines = [
            "\(oid("m"))\0\0refs/heads/main\0",
            "\(oid("m"))\0\0refs/remotes/origin/main\0",
            "\(oid("m"))\0\0refs/remotes/origin/HEAD\0refs/remotes/origin/main",
            "\(oid("tagobj"))\0\(oid("b"))\0refs/tags/v1.0\0",
            "\(oid("f"))\0\0refs/heads/feature/x\0",
            "\(oid("z"))\0\0refs/notes/commits\0",
        ]
        let refs = GitLogParser.parseRefs(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(refs, [
            GitRef(kind: .localBranch, name: "main", fullName: "refs/heads/main", target: oid("m")),
            GitRef(kind: .remoteBranch, name: "origin/main", fullName: "refs/remotes/origin/main", target: oid("m")),
            GitRef(kind: .tag, name: "v1.0", fullName: "refs/tags/v1.0", target: oid("b")),
            GitRef(kind: .localBranch, name: "feature/x", fullName: "refs/heads/feature/x", target: oid("f")),
        ])
        XCTAssertEqual(refs[1].remoteParts?.remote, "origin")
        XCTAssertEqual(refs[1].remoteParts?.branch, "main")
    }

    func testParsesNameStatusIncludingRenamesAndOddPaths() {
        let data = Data("M\0src/a b.swift\0A\0新しい 🚀.md\0D\0old\nline.txt\0R100\0from.txt\0to.txt\0C075\0x\0y\0T\0link\0".utf8)
        XCTAssertEqual(GitLogParser.parseNameStatus(data), [
            GitFileChange(status: .modified, path: "src/a b.swift"),
            GitFileChange(status: .added, path: "新しい 🚀.md"),
            GitFileChange(status: .deleted, path: "old\nline.txt"),
            GitFileChange(status: .renamed, path: "to.txt", oldPath: "from.txt"),
            GitFileChange(status: .copied, path: "y", oldPath: "x"),
            GitFileChange(status: .typeChanged, path: "link"),
        ])
        // 上限で切れた途中の名前は出さない。
        XCTAssertEqual(GitLogParser.parseNameStatus(Data("M\0a\0M\0trunc".utf8)), [GitFileChange(status: .modified, path: "a")])
    }

    func testParsesDetailWithMultilineBody() {
        let body = "件名\n\n本文 1 行目\n\u{1f}2 行目 🚀\n"
        let text = [oid("b"), "\(oid("a")) \(oid("c"))", "作者", "a@example.com", "1700000000",
                    "コミッター", "c@example.com", "1700000500", body].joined(separator: "\0")
        let detail = GitLogParser.parseDetail(Data(text.utf8), files: Data("A\0x.txt\0".utf8), filesTruncated: false)
        XCTAssertEqual(detail?.message, "件名\n\n本文 1 行目\n\u{1f}2 行目 🚀")
        XCTAssertEqual(detail?.parents, [oid("a"), oid("c")])
        XCTAssertEqual(detail?.committerName, "コミッター")
        XCTAssertEqual(detail?.commitDate, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(detail?.files, [GitFileChange(status: .added, path: "x.txt")])
        XCTAssertNil(GitLogParser.parseDetail(Data("broken".utf8), files: Data(), filesTruncated: false))
    }

    func testObjectIDCheck() {
        XCTAssertTrue(GitLogParser.isObjectID(oid("a")))
        XCTAssertTrue(GitLogParser.isObjectID(String(repeating: "a", count: 64)))
        XCTAssertFalse(GitLogParser.isObjectID("--output=x" + String(repeating: "a", count: 30)))
        XCTAssertFalse(GitLogParser.isObjectID(oid("z").uppercased()))
    }
}

final class GitGraphLayoutTests: XCTestCase {
    /// 上端から入る線は、前の行の下へ続く線と同じ列・同じ色（行をまたいで線が切れない・ずれない）。
    private func assertConnected(_ rows: [GitGraphRow], file: StaticString = #filePath, line: UInt = #line) {
        for (index, row) in rows.enumerated() {
            for edge in row.edges {
                XCTAssertTrue((0..<row.width).contains(edge.from) && (0..<row.width).contains(edge.to), "列が幅の外", file: file, line: line)
            }
            XCTAssertTrue(row.column < row.width, file: file, line: line)
            let bottoms = row.edges.filter { $0.toAnchor == .bottom }.map { GitGraphLane(column: $0.to, color: $0.color) }
            XCTAssertEqual(Set(bottoms.map(\.column)), Set(row.continuing.map(\.column)), "行 \(index) の下端", file: file, line: line)
            guard index > 0 else { continue }
            let tops = row.edges.filter { $0.fromAnchor == .top }.map { GitGraphLane(column: $0.from, color: $0.color) }
            XCTAssertEqual(tops.sorted { $0.column < $1.column }, rows[index - 1].continuing, "行 \(index) の上端", file: file, line: line)
        }
    }

    func testLinearHistoryStaysInOneColumn() {
        let rows = GitGraphLayout.rows(for: [commit("c", ["b"]), commit("b", ["a"]), commit("a")])
        XCTAssertEqual(rows.map(\.column), [0, 0, 0])
        XCTAssertEqual(Set(rows.map(\.color)), [0])
        XCTAssertEqual(rows[0].edges, [GitGraphEdge(from: 0, .center, to: 0, .bottom, color: 0)])
        XCTAssertEqual(rows[2].edges, [GitGraphEdge(from: 0, .top, to: 0, .center, color: 0)])
        XCTAssertEqual(rows[2].continuing, [])
        assertConnected(rows)
    }

    func testBranchAndMergeUseSecondColumnAndJoinBack() {
        // M = merge(C, F2)、F2 → F1 → B、C → B → A。
        let commits = [commit("M", ["C", "F2"]), commit("F2", ["F1"]), commit("C", ["B"]), commit("F1", ["B"]),
                       commit("B", ["A"]), commit("A")]
        let rows = GitGraphLayout.rows(for: commits)
        XCTAssertEqual(rows.map(\.column), [0, 1, 0, 1, 0, 0])
        XCTAssertEqual(rows[0].edges, [GitGraphEdge(from: 0, .center, to: 0, .bottom, color: 0),
                                       GitGraphEdge(from: 0, .center, to: 1, .bottom, color: 1)])
        XCTAssertEqual(rows[1].color, 1)
        // 分かれた所（B）で 2 本が合流し、その後は 1 列に詰まる。
        XCTAssertEqual(rows[4].edges.filter { $0.toAnchor == .center }.map(\.from), [0, 1])
        XCTAssertEqual(rows[4].continuing, [GitGraphLane(column: 0, color: 0)])
        XCTAssertEqual(rows.map(\.width).max(), 2)
        assertConnected(rows)
    }

    func testTwoHeadsWithSameParentRunParallelThenConverge() {
        let rows = GitGraphLayout.rows(for: [commit("X", ["P"]), commit("Y", ["P"]), commit("P")])
        XCTAssertEqual(rows.map(\.column), [0, 1, 0])
        XCTAssertNotEqual(rows[0].color, rows[1].color)
        XCTAssertEqual(rows[2].edges.count, 2)
        assertConnected(rows)
    }

    func testMultipleRootsAndOctopusMerge() {
        let commits = [commit("O", ["A", "B", "C"]), commit("A", ["R1"]), commit("B", ["R1"]), commit("C"),
                       commit("R1"), commit("Z", ["R2"]), commit("R2")]
        let rows = GitGraphLayout.rows(for: commits)
        XCTAssertEqual(rows[0].edges.filter { $0.fromAnchor == .center }.map(\.to), [0, 1, 2])
        XCTAssertEqual(Set(rows[0].edges.map(\.color)).count, 3)
        // 根（C）で列が終わり、別の根の履歴（Z → R2）は左へ詰めて 1 列から始まる。
        XCTAssertEqual(rows[3].continuing.count, 2)
        XCTAssertEqual(rows[4].continuing, [])
        XCTAssertEqual(rows[5].column, 0)
        XCTAssertEqual(rows[6].continuing, [])
        assertConnected(rows)
    }

    func testMergeOfAlreadyTrackedParentJoinsExistingLane() {
        // feature に main を取り込んだ（F2 = merge(F1, C)）。C は main の列がすでに待っている。
        let commits = [commit("C2", ["C"]), commit("F2", ["F1", "C"]), commit("C", ["B"]), commit("F1", ["B"]), commit("B")]
        let rows = GitGraphLayout.rows(for: commits)
        XCTAssertEqual(rows[1].column, 1)
        XCTAssertEqual(rows[1].edges.filter { $0.fromAnchor == .center }.map(\.to), [1, 0])
        XCTAssertEqual(rows.map(\.width).max(), 2)
        assertConnected(rows)
    }

    func testGeometryNarrowsLanesAndClampsOverflow() {
        let few = GitGraphGeometry(lanes: 3)
        XCTAssertEqual(few.laneWidth, 10)
        XCTAssertEqual(few.width, 34)
        XCTAssertEqual(few.x(0), 7)
        let many = GitGraphGeometry(lanes: 16)
        XCTAssertEqual(many.laneWidth, 6.25)
        XCTAssertEqual(many.visibleLanes, 16)
        XCTAssertLessThanOrEqual(many.width, GitGraphGeometry.targetWidth + GitGraphGeometry.padding)
        let overflow = GitGraphGeometry(lanes: 40)
        XCTAssertEqual(overflow.laneWidth, GitGraphGeometry.minLaneWidth)
        XCTAssertEqual(overflow.visibleLanes, 20)
        XCTAssertEqual(overflow.x(35), overflow.x(19))
        XCTAssertLessThan(overflow.x(35), overflow.width)
        XCTAssertEqual(GitGraphGeometry(lanes: 0).visibleLanes, 1)
    }

    /// 1〜40 本のどれでも、収まる本数までは列が重ならず、図の幅に収まる（割り算の誤差で最後の列を落とさない）。
    func testGeometryKeepsEveryLaneSeparateUpToTheLimit() {
        let limit = Int(GitGraphGeometry.targetWidth / GitGraphGeometry.minLaneWidth)
        for lanes in 1...40 {
            let geometry = GitGraphGeometry(lanes: lanes)
            XCTAssertEqual(geometry.visibleLanes, min(lanes, limit), "\(lanes) 本")
            let xs = (0..<lanes).map(geometry.x)
            XCTAssertEqual(Set(xs).count, min(lanes, limit), "\(lanes) 本で列が重なった")
            XCTAssertLessThanOrEqual(xs.max()! + geometry.dotRadius, geometry.width + 1e-9, "\(lanes) 本")
            XCTAssertLessThanOrEqual(geometry.width, GitGraphGeometry.targetWidth + GitGraphGeometry.padding + 1e-9, "\(lanes) 本")
        }
        XCTAssertEqual(GitGraphGeometry(lanes: 11).visibleLanes, 11)
    }

    func testParentsOutsideTheListRunToTheBottom() {
        let rows = GitGraphLayout.rows(for: [commit("B", ["A"]), commit("Y", ["X"])])
        XCTAssertEqual(rows[1].continuing.count, 2)
        assertConnected(rows)
    }

    func testColorsRotateWhenPaletteIsExhausted() {
        let heads = (0..<5).map { commit("h\($0)", ["base"]) } + [commit("base")]
        let rows = GitGraphLayout.rows(for: heads, paletteSize: 3)
        XCTAssertEqual(rows.prefix(3).map(\.color), [0, 1, 2])
        XCTAssertTrue(rows.allSatisfy { (0..<3).contains($0.color) })
        assertConnected(rows)
    }

    /// 枝分かれと合流を重ねた履歴でも、線がつながったまま列が増え続けない。
    func testRandomizedHistoryStaysConnected() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var names: [String] = []
            var commits: [GitCommit] = []
            for index in 0..<60 {
                let name = "n\(index)"
                var parents: [String] = []
                if !names.isEmpty && index % 17 != 0 {
                    parents.append(names[names.count - 1 - Int.random(in: 0..<min(3, names.count), using: &generator)])
                    if names.count > 3 && Bool.random(using: &generator) {
                        let other = names[Int.random(in: 0..<names.count, using: &generator)]
                        if !parents.contains(other) { parents.append(other) }
                    }
                }
                names.append(name)
                commits.append(commit(name, parents))
            }
            let rows = GitGraphLayout.rows(for: commits.reversed())
            assertConnected(rows)
        }
    }
}

final class GitRefLabelsTests: XCTestCase {
    func testMergesLocalAndRemoteOnSameCommitAndMarksHead() {
        let refs = [
            GitRef(kind: .localBranch, name: "main", fullName: "refs/heads/main", target: oid("m")),
            GitRef(kind: .remoteBranch, name: "origin/main", fullName: "refs/remotes/origin/main", target: oid("m")),
            GitRef(kind: .remoteBranch, name: "upstream/main", fullName: "refs/remotes/upstream/main", target: oid("m")),
            GitRef(kind: .tag, name: "v2", fullName: "refs/tags/v2", target: oid("m")),
            GitRef(kind: .localBranch, name: "a-topic", fullName: "refs/heads/a-topic", target: oid("m")),
            GitRef(kind: .remoteBranch, name: "origin/feature", fullName: "refs/remotes/origin/feature", target: oid("f")),
            GitRef(kind: .localBranch, name: "feature", fullName: "refs/heads/feature", target: oid("g")),
        ]
        let labels = GitRefLabels.labels(refs: refs, headRef: "refs/heads/main", headOid: oid("m"))
        XCTAssertEqual(labels[oid("m")], [
            GitRefLabel(kind: .branch, name: "main", remotes: ["origin", "upstream"], isCurrent: true),
            GitRefLabel(kind: .branch, name: "a-topic"),
            GitRefLabel(kind: .tag, name: "v2"),
        ])
        // 名前が同じでも別のコミットを指すリモートは別の札。
        XCTAssertEqual(labels[oid("f")], [GitRefLabel(kind: .remote, name: "origin/feature")])
        XCTAssertEqual(labels[oid("g")], [GitRefLabel(kind: .branch, name: "feature")])
        XCTAssertEqual(labels[oid("m")]?.first?.fullText, "HEAD → main（origin/main・upstream/main も同じ）")
    }

    func testCompactNameKeepsHeadAndTail() {
        XCTAssertEqual(GitRefLabel(kind: .branch, name: "feature/247").compactName(), "feature/247")
        XCTAssertEqual(GitRefLabel(kind: .remote, name: "origin/feature/very-long-name-251").compactName(), "origin/f…ame-251")
        XCTAssertEqual(GitRefLabel(kind: .remote, name: "origin/feature/very-long-name-251").compactName().count, 16)
    }

    func testDetachedHeadGetsItsOwnLabel() {
        let refs = [GitRef(kind: .tag, name: "v1", fullName: "refs/tags/v1", target: oid("d"))]
        let labels = GitRefLabels.labels(refs: refs, headRef: nil, headOid: oid("d"))
        XCTAssertEqual(labels[oid("d")], [GitRefLabel(kind: .head, name: "HEAD", isCurrent: true), GitRefLabel(kind: .tag, name: "v1")])
    }

    func testRelativeDates() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func ago(_ seconds: TimeInterval) -> String { GitDates.relative(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(ago(-30), "たった今")
        XCTAssertEqual(ago(59), "たった今")
        XCTAssertEqual(ago(60 * 5), "5分前")
        XCTAssertEqual(ago(3600 * 3), "3時間前")
        XCTAssertEqual(ago(86400 * 2), "2日前")
        XCTAssertEqual(ago(86400 * 65), "2か月前")
        XCTAssertEqual(ago(86400 * 800), "2年前")
    }

    func testLanePalettesAreVisibleOnThePanel() {
        for palette in [ThemePalette.night, ThemePalette.light] {
            XCTAssertEqual(palette.graphLanes.count, GitGraphLayout.defaultPaletteSize)
            XCTAssertEqual(Set(palette.graphLanes).count, palette.graphLanes.count)
            for color in palette.graphLanes {
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(color, palette.stagePanel), 3, String(format: "%06x", color))
            }
        }
    }
}
