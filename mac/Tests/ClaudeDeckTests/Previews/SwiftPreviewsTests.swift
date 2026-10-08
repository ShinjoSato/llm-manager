import XCTest
@testable import MonitorKit

final class SwiftPreviewsTests: XCTestCase {
    private func defs(_ source: String) -> [SwiftPreviewDefinition] {
        SwiftPreviews.definitions(in: source)
    }

    func testNamedUnnamedAndTraits() {
        let source = """
        import SwiftUI

        #Preview {
            Text("a")
        }

        #Preview("広告あり") {
            Text("b")
        }

        #Preview("Sheet", traits: .sizeThatFitsLayout) { Text("c") }
        #Preview(traits: .landscapeLeft) { Text("d") }
        @available(iOS 17, *)
        #Preview(
            "折り返し"
        ) { Text("e") }
        """
        XCTAssertEqual(defs(source), [
            SwiftPreviewDefinition(index: 0, name: nil, line: 3),
            SwiftPreviewDefinition(index: 1, name: "広告あり", line: 7),
            SwiftPreviewDefinition(index: 2, name: "Sheet", line: 11),
            SwiftPreviewDefinition(index: 3, name: nil, line: 12),
            SwiftPreviewDefinition(index: 4, name: "折り返し", line: 14),
        ])
    }

    func testIgnoresCommentsAndStrings() {
        let source = #"""
        // #Preview { }
        /* #Preview { } /* 入れ子 #Preview */ まだコメント #Preview */
        let a = "#Preview"
        let b = """
            #Preview("x") { }
            """
        let c = ##"raw "#Preview" "##
        let d = "\(foo("#Preview", bar(")")))"
        let e = "1 行の \"#Preview\""
        #Preview("本物") { Text("\(1 + (2))") }
        """#
        XCTAssertEqual(defs(source), [SwiftPreviewDefinition(index: 0, name: "本物", line: 10)])
    }

    func testRawStringNameAndEscapes() {
        XCTAssertEqual(defs(##"#Preview(#"raw "名""#) { }"##).first?.name, #"raw "名""#)
        XCTAssertEqual(defs(#"#Preview("a\"b") { }"#).first?.name, #"a"b"#)
        // 補間のある名前は読めないので名前なしとして数える。
        XCTAssertEqual(defs(#"#Preview("n\(1)") { }"#), [SwiftPreviewDefinition(index: 0, name: nil, line: 1)])
    }

    func testNotPreviewMacroWords() {
        XCTAssertEqual(defs("#PreviewX { }\nx#Preview { }\nlet p = #Preview"), [SwiftPreviewDefinition(index: 0, name: nil, line: 3)])
    }

    func testPreviewProviderIsCountedButNotListed() {
        let source = """
        #Preview("first") { }
        struct Old_Previews: PreviewProvider {
            static var previews: some View { Text("x") }
        }
        // struct Commented: PreviewProvider {}
        struct Other: View, PreviewProvider { }
        let x: PreviewProviderLike = y
        #Preview("third") { }
        """
        XCTAssertEqual(defs(source), [
            SwiftPreviewDefinition(index: 0, name: "first", line: 1),
            SwiftPreviewDefinition(index: 3, name: "third", line: 8),
        ])
    }

    func testPreviewProviderOnlyInTypeDeclarations() {
        let source = """
        struct A: SwiftUI.PreviewProvider { }
        struct G<T: PreviewProvider> { }
        func f(_ p: PreviewProvider) { }
        let x: PreviewProvider = y
        var z: any PreviewProvider
        extension Box where T: PreviewProvider { }
        final class C<T>: Base<T>, SwiftUI.View, PreviewProvider { }
        extension Outer.Inner: PreviewProvider { }
        @MainActor
        enum E:
            PreviewProvider { }
        protocol P: PreviewProvider { }
        #Preview("after") { }
        """
        // 数えるのは A・C・Outer.Inner・E の 4 つ（制約・注釈・プロトコルは数えない）。
        XCTAssertEqual(defs(source), [SwiftPreviewDefinition(index: 4, name: "after", line: 13)])
    }

    func testDeepInterpolationStopsWithoutCrashing() {
        // 補間の入れ子が深すぎるソースは、そこで読むのをやめる（スタックを使い切らない）。
        let depth = 5_000
        let nested = String(repeating: #""\("#, count: depth) + String(repeating: #")""#, count: depth)
        let source = "#Preview(\"前\") { }\nlet s = \(nested)\n#Preview(\"後\") { }"
        XCTAssertEqual(defs(source).map(\.name), ["前"])
        // 上限より浅い入れ子は最後まで読む。
        let shallow = String(repeating: #""\("#, count: 8) + "1" + String(repeating: #")""#, count: 8)
        XCTAssertEqual(defs("let s = \(shallow)\n#Preview(\"後\") { }").map(\.name), ["後"])
    }

    func testMultilineStringCountsLines() {
        let source = "let s = \"\"\"\nline\nline\n\"\"\"\n/* a\nb */\n#Preview { }"
        XCTAssertEqual(defs(source), [SwiftPreviewDefinition(index: 0, name: nil, line: 7)])
    }

    func testScanSkipsBuildFoldersAndSortsNaturally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ relative: String, _ text: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("App/View10.swift", "#Preview { }")
        try write("App/View2.swift", "#Preview(\"a\") { }\n#Preview(\"b\") { }")
        try write("App/Plain.swift", "struct A {}")
        try write("App/Commented.swift", "// #Preview { }")
        try write(".build/Gen.swift", "#Preview { }")
        try write("DerivedData/X.swift", "#Preview { }")
        try write("Pods/P.swift", "#Preview { }")
        try write("node_modules/n/N.swift", "#Preview { }")
        try write(".hidden/H.swift", "#Preview { }")
        try write("App.xcodeproj/Inside.swift", "#Preview { }")
        try write("Top.swift", "#Preview { }")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.swift"),
                                                   withDestinationURL: root.appendingPathComponent("Top.swift"))
        let scan = SwiftPreviews.scan(root: root.path)
        XCTAssertEqual(scan.files.map(\.relativePath), ["App/View2.swift", "App/View10.swift", "Top.swift"])
        XCTAssertEqual(scan.count, 4)
        XCTAssertFalse(scan.truncated)
        XCTAssertNotNil(scan.files.first?.modified)
        XCTAssertEqual(scan.files.first?.path, root.appendingPathComponent("App/View2.swift").path)
    }

    func testScanTruncatesAtFileLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<5 { try Data("#Preview { }".utf8).write(to: root.appendingPathComponent("V\(i).swift")) }
        let scan = SwiftPreviews.scan(root: root.path, maxFiles: 3)
        XCTAssertEqual(scan.files.count, 3)
        XCTAssertTrue(scan.truncated)
    }

    func testScanRootIsFolderOfXcodeProject() {
        XCTAssertEqual(SwiftPreviews.scanRoot(forXcodeProject: "/p/ios/App.xcodeproj"), "/p/ios")
    }
}
