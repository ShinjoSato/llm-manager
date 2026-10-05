import Foundation

/// 実行ファイルの署名（とシミュレータ向けの `__TEXT,__entitlements`）からエンタイトルメントを読む。
/// CKContainer はエンタイトルメントが無いとプロセスごと落ちるので、作る前にこれで確かめる。
/// iOS には自分のエンタイトルメントを問い合わせる API が無く、App Store / TestFlight の版は embedded.mobileprovision を持たないため、署名を直接読む。
public enum ExecutableEntitlements {
    public typealias Values = [String: Any]

    public static func ofMainExecutable() -> Values? {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return read(data)
    }

    /// Mach-O（単一または fat）を読む。署名のエンタイトルメントを優先し、無いか空なら `__TEXT,__entitlements` を見る。
    public static func read(_ data: Data) -> Values? {
        guard data.count >= 8 else { return nil }
        if beUInt32(data, 0) == 0xcafe_babe {
            let count = Int(beUInt32(data, 4) ?? 0)
            var slices: [Data] = []
            for index in 0..<min(count, 16) {
                let base = 8 + index * 20
                guard let cpu = beUInt32(data, base), let offset = beUInt32(data, base + 8), let size = beUInt32(data, base + 12),
                      Int(offset) + Int(size) <= data.count else { continue }
                let slice = data.subdata(in: data.startIndex + Int(offset) ..< data.startIndex + Int(offset) + Int(size))
                if cpu == hostCPUType { slices.insert(slice, at: 0) } else { slices.append(slice) }
            }
            for slice in slices { if let values = readThin(slice) { return values } }
            return nil
        }
        return readThin(data)
    }

    #if arch(arm64)
    static let hostCPUType: UInt32 = 0x0100_000c
    #else
    static let hostCPUType: UInt32 = 0x0100_0007
    #endif

    static func readThin(_ data: Data) -> Values? {
        guard leUInt32(data, 0) == 0xfeed_facf, let ncmds = leUInt32(data, 16) else { return nil }
        var offset = 32
        var fromSignature: Values?
        var fromSection: Values?
        for _ in 0..<min(Int(ncmds), 4096) {
            guard let cmd = leUInt32(data, offset), let size = leUInt32(data, offset + 4), size >= 8 else { break }
            switch cmd {
            case 0x1d: // LC_CODE_SIGNATURE
                if let dataoff = leUInt32(data, offset + 8), let datasize = leUInt32(data, offset + 12) {
                    fromSignature = signatureEntitlements(data, at: Int(dataoff), size: Int(datasize))
                }
            case 0x19: // LC_SEGMENT_64
                if fromSection == nil, name(data, offset + 8) == "__TEXT", let nsects = leUInt32(data, offset + 64) {
                    for index in 0..<min(Int(nsects), 256) {
                        let sect = offset + 72 + index * 80
                        guard name(data, sect) == "__entitlements", let size = leUInt64(data, sect + 40),
                              let fileOffset = leUInt32(data, sect + 48) else { continue }
                        fromSection = plist(data, at: Int(fileOffset), size: Int(size))
                    }
                }
            default:
                break
            }
            offset += Int(size)
        }
        // シミュレータ向けの版は署名のエンタイトルメントが空で、`__entitlements` の方が効く。
        if let fromSignature, !fromSignature.isEmpty { return fromSignature }
        return fromSection ?? fromSignature
    }

    /// 署名の SuperBlob（ビッグエンディアン）からエンタイトルメントの blob（種類 5）を探す。
    static func signatureEntitlements(_ data: Data, at start: Int, size: Int) -> Values? {
        guard beUInt32(data, start) == 0xfade_0cc0, let count = beUInt32(data, start + 8) else { return nil }
        for index in 0..<min(Int(count), 64) {
            let entry = start + 12 + index * 8
            guard let type = beUInt32(data, entry), let blobOffset = beUInt32(data, entry + 4), type == 5 else { continue }
            let blob = start + Int(blobOffset)
            guard Int(blobOffset) < size, beUInt32(data, blob) == 0xfade_7171, let length = beUInt32(data, blob + 4), length >= 8 else {
                continue
            }
            return plist(data, at: blob + 8, size: Int(length) - 8)
        }
        return nil
    }

    static func plist(_ data: Data, at start: Int, size: Int) -> Values? {
        guard start >= 0, size > 0, start + size <= data.count else { return nil }
        let body = data.subdata(in: data.startIndex + start ..< data.startIndex + start + size)
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? Values
    }

    private static func name(_ data: Data, _ at: Int) -> String? {
        guard at >= 0, at + 16 <= data.count else { return nil }
        let raw = data.subdata(in: data.startIndex + at ..< data.startIndex + at + 16)
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func leUInt32(_ data: Data, _ at: Int) -> UInt32? { uint(data, at, 4, littleEndian: true).map(UInt32.init) }
    private static func leUInt64(_ data: Data, _ at: Int) -> UInt64? { uint(data, at, 8, littleEndian: true) }
    private static func beUInt32(_ data: Data, _ at: Int) -> UInt32? { uint(data, at, 4, littleEndian: false).map(UInt32.init) }

    private static func uint(_ data: Data, _ at: Int, _ width: Int, littleEndian: Bool) -> UInt64? {
        guard at >= 0, at + width <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<width {
            let byte = UInt64(data[data.startIndex + at + (littleEndian ? width - 1 - index : index)])
            value = value << 8 | byte
        }
        return value
    }
}

extension AttentionNoticeSchema {
    /// CloudKit と共有コンテナ（受け手はプッシュも）のエンタイトルメントが揃っているか。
    public static func entitlementsAllowNotices(_ values: [String: Any]?, needsPush: Bool) -> Bool {
        guard let values else { return false }
        let services = values["com.apple.developer.icloud-services"] as? [String] ?? []
        let containers = values["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        guard services.contains("CloudKit"), containers.contains(containerIdentifier) else { return false }
        return !needsPush || (values["aps-environment"] as? String)?.isEmpty == false
    }
}
