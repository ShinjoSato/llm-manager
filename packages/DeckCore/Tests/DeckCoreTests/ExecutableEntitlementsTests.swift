import XCTest
@testable import DeckCore

final class ExecutableEntitlementsTests: XCTestCase {
    private let container = "iCloud.example.claude-deck"
    private var cloudKit: [String: Any] {
        ["aps-environment": "development",
         "com.apple.developer.icloud-services": ["CloudKit"],
         "com.apple.developer.icloud-container-identifiers": [container]]
    }

    private func xml(_ values: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    private func name16(_ s: String) -> [UInt8] { Array(s.utf8) + Array(repeating: 0, count: 16 - s.utf8.count) }

    /// 署名にエンタイトルメントを持つ最小の Mach-O。
    private func signedMachO(_ values: [String: Any]) -> Data {
        let plist = [UInt8](xml(values))
        let entBlob = be32(0xfade_7171) + be32(UInt32(8 + plist.count)) + plist
        let superBlob = be32(0xfade_0cc0) + be32(UInt32(12 + 8 + entBlob.count)) + be32(1) + be32(5) + be32(20) + entBlob
        let headerSize = 32 + 16
        var out = le32(0xfeed_facf) + le32(0x0100_000c) + le32(0) + le32(2) + le32(1) + le32(16) + le32(0) + le32(0)
        out += le32(0x1d) + le32(16) + le32(UInt32(headerSize)) + le32(UInt32(superBlob.count))
        out += superBlob
        return Data(out)
    }

    /// シミュレータ向けの `__TEXT,__entitlements` だけを持つ最小の Mach-O。
    private func sectionMachO(_ values: [String: Any]) -> Data {
        let plist = [UInt8](xml(values))
        let commandSize = 72 + 80
        let dataOffset = 32 + commandSize
        var out = le32(0xfeed_facf) + le32(0x0100_000c) + le32(0) + le32(2) + le32(1) + le32(UInt32(commandSize)) + le32(0) + le32(0)
        out += le32(0x19) + le32(UInt32(commandSize)) + name16("__TEXT") + le64(0) + le64(0) + le64(0) + le64(0)
        out += le32(5) + le32(5) + le32(1) + le32(0)
        out += name16("__entitlements") + name16("__TEXT") + le64(0) + le64(UInt64(plist.count)) + le32(UInt32(dataOffset))
        out += le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0)
        out += plist
        return Data(out)
    }

    /// 署名と `__entitlements` の両方を持つ Mach-O（シミュレータ向けの版は署名側が空）。
    private func bothMachO(signature: [String: Any], section: [String: Any]) -> Data {
        let sectPlist = [UInt8](xml(section))
        let sigPlist = [UInt8](xml(signature))
        let entBlob = be32(0xfade_7171) + be32(UInt32(8 + sigPlist.count)) + sigPlist
        let superBlob = be32(0xfade_0cc0) + be32(UInt32(20 + entBlob.count)) + be32(1) + be32(5) + be32(20) + entBlob
        let commands = 72 + 80 + 16
        let sectOffset = 32 + commands
        let sigOffset = sectOffset + sectPlist.count
        var out = le32(0xfeed_facf) + le32(0x0100_000c) + le32(0) + le32(2) + le32(2) + le32(UInt32(commands)) + le32(0) + le32(0)
        out += le32(0x19) + le32(152) + name16("__TEXT") + le64(0) + le64(0) + le64(0) + le64(0)
        out += le32(5) + le32(5) + le32(1) + le32(0)
        out += name16("__entitlements") + name16("__TEXT") + le64(0) + le64(UInt64(sectPlist.count)) + le32(UInt32(sectOffset))
        out += le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0)
        out += le32(0x1d) + le32(16) + le32(UInt32(sigOffset)) + le32(UInt32(superBlob.count))
        out += sectPlist + superBlob
        return Data(out)
    }

    func testEmptySignatureFallsBackToTheSimulatorSection() {
        let simulator = ExecutableEntitlements.read(bothMachO(signature: [:], section: cloudKit))
        XCTAssertTrue(AttentionNoticeSchema.entitlementsAllowNotices(simulator, container: container, needsPush: true))
        // 署名に中身があれば署名が優先（実機では署名だけが効く）。
        let device = ExecutableEntitlements.read(bothMachO(signature: ["get-task-allow": true], section: cloudKit))
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(device, container: container, needsPush: false))
    }

    private func fat(_ slice: Data, cpu: UInt32) -> Data {
        var out = be32(0xcafe_babe) + be32(1) + be32(cpu) + be32(0) + be32(28) + be32(UInt32(slice.count)) + be32(0)
        out += [UInt8](slice)
        return Data(out)
    }

    func testReadsEntitlementsFromTheSignature() {
        let values = ExecutableEntitlements.read(signedMachO(cloudKit))
        XCTAssertEqual(values?["aps-environment"] as? String, "development")
        XCTAssertTrue(AttentionNoticeSchema.entitlementsAllowNotices(values, container: container, needsPush: true))
    }

    func testReadsTheSimulatorSection() {
        let values = ExecutableEntitlements.read(sectionMachO(cloudKit))
        XCTAssertTrue(AttentionNoticeSchema.entitlementsAllowNotices(values, container: container, needsPush: true))
    }

    func testReadsAFatSlice() {
        let values = ExecutableEntitlements.read(fat(signedMachO(cloudKit), cpu: ExecutableEntitlements.hostCPUType))
        XCTAssertTrue(AttentionNoticeSchema.entitlementsAllowNotices(values, container: container, needsPush: false))
    }

    func testMissingOrBrokenIsNil() {
        XCTAssertNil(ExecutableEntitlements.read(Data()))
        XCTAssertNil(ExecutableEntitlements.read(Data("not a mach-o".utf8)))
        var truncated = signedMachO(cloudKit)
        truncated.removeLast(40)
        XCTAssertNil(ExecutableEntitlements.read(truncated))
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(nil, container: container, needsPush: false))
    }

    func testRequiresCloudKitContainerAndPush() {
        var noPush = cloudKit
        noPush["aps-environment"] = nil
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(noPush, container: container, needsPush: true))
        XCTAssertTrue(AttentionNoticeSchema.entitlementsAllowNotices(noPush, container: container, needsPush: false))
        var otherContainer = cloudKit
        otherContainer["com.apple.developer.icloud-container-identifiers"] = ["iCloud.other"]
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(otherContainer, container: container, needsPush: false))
        var documentsOnly = cloudKit
        documentsOnly["com.apple.developer.icloud-services"] = ["CloudDocuments"]
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(documentsOnly, container: container, needsPush: false))
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(cloudKit, container: "", needsPush: false))
    }

    func testContainerFromInfoPlist() {
        XCTAssertEqual(AttentionNoticeSchema.containerIdentifier(infoValue: " iCloud.example.claude-deck "), "iCloud.example.claude-deck")
        XCTAssertNil(AttentionNoticeSchema.containerIdentifier(infoValue: nil))
        XCTAssertNil(AttentionNoticeSchema.containerIdentifier(infoValue: ""))
        XCTAssertNil(AttentionNoticeSchema.containerIdentifier(infoValue: "$(DECK_ICLOUD_CONTAINER)"))
        XCTAssertNil(AttentionNoticeSchema.containerIdentifier(infoValue: 1))
    }

    /// 試験の実行ファイルは iCloud のエンタイトルメントを持たない。
    func testTheTestRunnerHasNoCloudKit() {
        XCTAssertFalse(AttentionNoticeSchema.entitlementsAllowNotices(ExecutableEntitlements.ofMainExecutable(), container: container, needsPush: false))
    }

    #if os(macOS)
    /// 実物の署名（fat・arm64e）でも読めること。
    func testReadsARealSignedBinary() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator")
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw XCTSkip("Calculator が無い") }
        let values = ExecutableEntitlements.read(data)
        XCTAssertEqual(values?["com.apple.security.app-sandbox"] as? Bool, true)
    }
    #endif
}
