import CryptoKit
import Darwin
import Foundation

/// App Store Connect API の鍵。中身は文字列にしない。
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

/// 鍵の設定をどこから読んだか（画面に出すのは名前だけで、値は出さない）。
public struct AppStoreCredentialSource: Equatable, Sendable {
    /// 環境変数から採ったキーの名前。
    public var environmentKeys: [String]
    /// `~/.claude/appstore-meta.env` から採ったか。
    public var envFile: Bool

    public init(environmentKeys: [String] = [], envFile: Bool = false) {
        self.environmentKeys = environmentKeys
        self.envFile = envFile
    }

    public var label: String {
        let env = environmentKeys.isEmpty ? nil : "環境変数（\(environmentKeys.joined(separator: "・"))）"
        let file = envFile ? AppStoreEnvFile.displayPath : nil
        let parts = [env, file].compactMap { $0 }
        return parts.isEmpty ? "なし" : parts.joined(separator: " と ")
    }
}

/// env から読んだ鍵の設定。鍵そのものはトークンを作る時にだけ読む。
public struct AppStoreKeySettings: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum KeySpec: Sendable {
        case inline(String)
        case path(String)
    }

    public let keyID: String
    public let issuerID: String
    public let source: AppStoreCredentialSource
    let key: KeySpec

    public var description: String { "AppStoreKeySettings(<伏せています>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// 試験用: 鍵を PEM で直に渡す。
    public static func inline(keyID: String, issuerID: String, pem: String,
                              source: AppStoreCredentialSource = AppStoreCredentialSource(envFile: true)) -> AppStoreKeySettings {
        AppStoreKeySettings(keyID: keyID, issuerID: issuerID, source: source, key: .inline(pem))
    }

    public func loadCredentials() -> Result<AppStoreCredentials, AppStoreCredentialProblem> {
        let pem: String
        switch key {
        case .inline(let text):
            pem = text.replacingOccurrences(of: "\\n", with: "\n")
        case .path(let path):
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return .failure(.privateKeyPathNotAbsolute(path: path)) }
            switch AppStoreEnvFile.readRegularFile(expanded, max: AppStoreEnvFile.maxBytes) {
            case .success(let data):
                guard let text = String(data: data, encoding: .utf8) else { return .failure(.privateKeyFileUnreadable(path: path)) }
                pem = text
            case .failure(.missing): return .failure(.privateKeyFileMissing(path: path))
            case .failure: return .failure(.privateKeyFileUnreadable(path: path))
            }
        }
        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: pem.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.privateKeyInvalid)
        }
        return .success(AppStoreCredentials(keyID: keyID, issuerID: issuerID, privateKey: privateKey))
    }
}

/// 鍵が使えない理由。画面に出す文言は何が足りないかだけで、値は含めない。
public enum AppStoreCredentialProblem: Error, Equatable, Sendable {
    case envFileMissing(path: String)
    case envFileUnreadable(path: String)
    case missingKeyID
    case missingIssuerID
    case missingPrivateKey
    case privateKeyPathNotAbsolute(path: String)
    case privateKeyFileMissing(path: String)
    case privateKeyFileUnreadable(path: String)
    case privateKeyInvalid

    public var message: String {
        let file = AppStoreEnvFile.displayPath
        switch self {
        case .envFileMissing:
            return "\(file) がありません。appstore-plugin と同じ書式で ASC_KEY_ID・ASC_ISSUER_ID・ASC_PRIVATE_KEY_PATH（か ASC_PRIVATE_KEY）を書いてください"
        case .envFileUnreadable:
            return "\(file) を読めませんでした（通常のファイルか・権限・文字コードを確かめてください）"
        case .missingKeyID:
            return "ASC_KEY_ID がありません（環境変数か \(file) に書いてください）"
        case .missingIssuerID:
            return "ASC_ISSUER_ID がありません（環境変数か \(file) に書いてください）"
        case .missingPrivateKey:
            return "ASC_PRIVATE_KEY_PATH（.p8 のパス）か ASC_PRIVATE_KEY がありません（環境変数か \(file) に書いてください）"
        case .privateKeyPathNotAbsolute(let path):
            return "ASC_PRIVATE_KEY_PATH は絶対パス（/ か ~/ で始まる）で書いてください（\(path)）"
        case .privateKeyFileMissing(let path):
            return "ASC_PRIVATE_KEY_PATH のファイルが見つかりません（\(path)）"
        case .privateKeyFileUnreadable(let path):
            return "ASC_PRIVATE_KEY_PATH のファイルを読めませんでした（通常のファイルか・権限を確かめてください: \(path)）"
        case .privateKeyInvalid:
            return "秘密鍵を読めませんでした（App Store Connect で発行した .p8（P-256）か確かめてください）"
        }
    }
}

/// `KEY=value` の行の env ファイル（asc-lib.mjs の loadEnvFile と同じ読み方）。
/// 読み元は環境変数と `~/.claude/appstore-meta.env` だけで、プロジェクトの `.env` は読まない（他の秘密を読み込まないため）。
public enum AppStoreEnvFile {
    public static let displayPath = "~/.claude/appstore-meta.env"
    /// 鍵の .p8 は数百バイト。大きなファイルを読み込まないための上限。
    static let maxBytes = 64 * 1024
    static let keys = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH"]

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

    /// 環境変数を先に、足りない分を env ファイルから埋める（鍵の中身はまだ読まない）。
    public static func settings(fileURL: URL = defaultURL(), environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Result<AppStoreKeySettings, AppStoreCredentialProblem> {
        var values: [String: String] = [:]
        var source = AppStoreCredentialSource()
        for key in keys {
            if let value = environment[key], !value.isEmpty {
                values[key] = value
                source.environmentKeys.append(key)
            }
        }
        switch readRegularFile(fileURL.path, max: maxBytes) {
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8) else { return .failure(.envFileUnreadable(path: fileURL.path)) }
            for (key, value) in parse(text) where keys.contains(key) && values[key] == nil && !value.isEmpty {
                values[key] = value
                source.envFile = true
            }
        case .failure(.missing):
            if values.isEmpty { return .failure(.envFileMissing(path: fileURL.path)) }
        case .failure:
            return .failure(.envFileUnreadable(path: fileURL.path))
        }
        guard let keyID = values["ASC_KEY_ID"] else { return .failure(.missingKeyID) }
        guard let issuerID = values["ASC_ISSUER_ID"] else { return .failure(.missingIssuerID) }
        let key: AppStoreKeySettings.KeySpec
        if let inline = values["ASC_PRIVATE_KEY"] {
            key = .inline(inline)
        } else if let path = values["ASC_PRIVATE_KEY_PATH"] {
            key = .path(path)
        } else {
            return .failure(.missingPrivateKey)
        }
        return .success(AppStoreKeySettings(keyID: keyID, issuerID: issuerID, source: source, key: key))
    }

    /// 設定を読み、続けて鍵も読む（試験と一度きりの確かめ用）。
    public static func load(fileURL: URL = defaultURL(), environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Result<AppStoreCredentials, AppStoreCredentialProblem> {
        settings(fileURL: fileURL, environment: environment).flatMap { $0.loadCredentials() }
    }

    enum ReadFailure: Error, Equatable {
        case missing, notRegular, tooLarge, unreadable
    }

    /// リンクを辿った先が通常のファイルの時だけ読む（FIFO やデバイスで止まらないよう、開く時も待たない）。
    static func readRegularFile(_ path: String, max: Int) -> Result<Data, ReadFailure> {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegular) }
        guard info.st_size <= off_t(max) else { return .failure(.tooLarge) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadable)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > max { return .failure(.tooLarge) }
        }
        return .success(data)
    }
}
