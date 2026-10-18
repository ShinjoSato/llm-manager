import CryptoKit
import Foundation

/// App Store Connect API の鍵（appstore-plugin と同じ `~/.claude/appstore-meta.env` から読む）。中身は文字列にしない。
public struct AppStoreCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let keyID: String
    public let issuerID: String
    let privateKey: P256.Signing.PrivateKey

    public init(keyID: String, issuerID: String, privateKey: P256.Signing.PrivateKey) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKey = privateKey
    }

    // 誤って print やログに渡しても鍵と ID が出ないようにする。
    public var description: String { "AppStoreCredentials(<伏せています>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// 鍵が使えない理由。画面に出す文言は何が足りないかだけで、値は含めない。
public enum AppStoreCredentialProblem: Error, Equatable, Sendable {
    case envFileMissing(path: String)
    case envFileUnreadable(path: String)
    case missingKeyID
    case missingIssuerID
    case missingPrivateKey
    case privateKeyFileMissing(path: String)
    case privateKeyFileUnreadable(path: String)
    case privateKeyInvalid

    public var message: String {
        let file = AppStoreEnvFile.displayPath
        switch self {
        case .envFileMissing:
            return "\(file) がありません。appstore-plugin と同じ書式で ASC_KEY_ID・ASC_ISSUER_ID・ASC_PRIVATE_KEY_PATH（か ASC_PRIVATE_KEY）を書いてください"
        case .envFileUnreadable:
            return "\(file) を読めませんでした（権限か文字コードを確かめてください）"
        case .missingKeyID:
            return "\(file) に ASC_KEY_ID がありません"
        case .missingIssuerID:
            return "\(file) に ASC_ISSUER_ID がありません"
        case .missingPrivateKey:
            return "\(file) に ASC_PRIVATE_KEY_PATH（.p8 のパス）か ASC_PRIVATE_KEY がありません"
        case .privateKeyFileMissing(let path):
            return "ASC_PRIVATE_KEY_PATH のファイルが見つかりません（\(path)）"
        case .privateKeyFileUnreadable(let path):
            return "ASC_PRIVATE_KEY_PATH のファイルを読めませんでした（\(path)）"
        case .privateKeyInvalid:
            return "秘密鍵を読めませんでした（App Store Connect で発行した .p8（P-256）か確かめてください）"
        }
    }
}

/// `KEY=value` の行の env ファイル（asc-lib.mjs の loadEnvFile と同じ読み方）。
public enum AppStoreEnvFile {
    public static let displayPath = "~/.claude/appstore-meta.env"
    /// 鍵の .p8 は数百バイト。大きなファイルを読み込まないための上限。
    static let maxBytes = 64 * 1024

    public static func defaultURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/appstore-meta.env")
    }

    /// 空行・`#` の行・`=` の無い行は飛ばし、`export ` を外し、値を囲む引用符を 1 組だけ外す。同じキーは先のものを採る。
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, result[key] == nil { result[key] = value }
        }
        return result
    }

    /// 環境変数を先に、足りない分を env ファイルから埋める（appstore-plugin と同じ優先順）。
    public static func load(fileURL: URL = defaultURL(), environment: [String: String] = ProcessInfo.processInfo.environment,
                            fileManager: FileManager = .default) -> Result<AppStoreCredentials, AppStoreCredentialProblem> {
        var values: [String: String] = [:]
        for key in ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH"] {
            if let value = environment[key], !value.isEmpty { values[key] = value }
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            guard let text = readSmallText(fileURL) else { return .failure(.envFileUnreadable(path: fileURL.path)) }
            for (key, value) in parse(text) where values[key] == nil && !value.isEmpty { values[key] = value }
        } else if values.isEmpty {
            return .failure(.envFileMissing(path: fileURL.path))
        }
        return credentials(from: values, fileManager: fileManager)
    }

    static func credentials(from values: [String: String], fileManager: FileManager = .default) -> Result<AppStoreCredentials, AppStoreCredentialProblem> {
        guard let keyID = values["ASC_KEY_ID"], !keyID.isEmpty else { return .failure(.missingKeyID) }
        guard let issuerID = values["ASC_ISSUER_ID"], !issuerID.isEmpty else { return .failure(.missingIssuerID) }
        let pem: String
        if let inline = values["ASC_PRIVATE_KEY"], !inline.isEmpty {
            pem = inline.replacingOccurrences(of: "\\n", with: "\n")
        } else if let path = values["ASC_PRIVATE_KEY_PATH"], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: expanded) else { return .failure(.privateKeyFileMissing(path: path)) }
            guard let text = readSmallText(URL(fileURLWithPath: expanded)) else { return .failure(.privateKeyFileUnreadable(path: path)) }
            pem = text
        } else {
            return .failure(.missingPrivateKey)
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.privateKeyInvalid)
        }
        return .success(AppStoreCredentials(keyID: keyID, issuerID: issuerID, privateKey: key))
    }

    private static func readSmallText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let read: Data?
        do { read = try handle.read(upToCount: maxBytes + 1) } catch { return nil }
        let data = read ?? Data()
        guard data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
