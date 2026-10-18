import CryptoKit
import XCTest
@testable import MonitorKit

final class AppStoreEnvFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("asc-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParseFollowsPluginFormat() {
        let text = """
        # コメント
        export ASC_KEY_ID=KEY123
          ASC_ISSUER_ID = "issuer-uuid"
        ASC_PRIVATE_KEY_PATH='~/keys/AuthKey.p8'
        BROKEN LINE
        ASC_KEY_ID=second
        EMPTY=
        """
        let values = AppStoreEnvFile.parse(text)
        XCTAssertEqual(values["ASC_KEY_ID"], "KEY123")
        XCTAssertEqual(values["ASC_ISSUER_ID"], "issuer-uuid")
        XCTAssertEqual(values["ASC_PRIVATE_KEY_PATH"], "~/keys/AuthKey.p8")
        XCTAssertEqual(values["EMPTY"], "")
        XCTAssertNil(values["BROKEN LINE"])
    }

    func testLoadsKeyFromPath() throws {
        let key = P256.Signing.PrivateKey()
        let p8 = try write(key.pemRepresentation, "AuthKey_TEST.p8")
        let env = try write("ASC_KEY_ID=KEY1\nASC_ISSUER_ID=ISS1\nASC_PRIVATE_KEY_PATH=\(p8.path)\n", "appstore-meta.env")
        let credentials = try AppStoreEnvFile.load(fileURL: env, environment: [:]).get()
        XCTAssertEqual(credentials.keyID, "KEY1")
        XCTAssertEqual(credentials.issuerID, "ISS1")
        XCTAssertEqual(credentials.privateKey.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    func testLoadsInlineKeyWithEscapedNewlines() throws {
        let key = P256.Signing.PrivateKey()
        let inline = key.pemRepresentation.replacingOccurrences(of: "\n", with: "\\n")
        let env = try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_PRIVATE_KEY=\"\(inline)\"\n", "a.env")
        let credentials = try AppStoreEnvFile.load(fileURL: env, environment: [:]).get()
        XCTAssertEqual(credentials.privateKey.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    /// appstore-plugin と同じく、環境変数が先で足りない分をファイルから埋める。
    func testEnvironmentTakesPrecedence() throws {
        let key = P256.Signing.PrivateKey()
        let p8 = try write(key.pemRepresentation, "k.p8")
        let env = try write("ASC_KEY_ID=FILE\nASC_ISSUER_ID=FILEISS\nASC_PRIVATE_KEY_PATH=\(p8.path)\n", "a.env")
        let credentials = try AppStoreEnvFile.load(fileURL: env, environment: ["ASC_KEY_ID": "ENV"]).get()
        XCTAssertEqual(credentials.keyID, "ENV")
        XCTAssertEqual(credentials.issuerID, "FILEISS")
    }

    func testProblemsSayWhatIsMissing() throws {
        let missing = dir.appendingPathComponent("none.env")
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: missing, environment: [:]).failure, .envFileMissing(path: missing.path))
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: try write("ASC_ISSUER_ID=I\n", "1.env"), environment: [:]).failure, .missingKeyID)
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: try write("ASC_KEY_ID=K\n", "2.env"), environment: [:]).failure, .missingIssuerID)
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\n", "3.env"), environment: [:]).failure,
                       .missingPrivateKey)
        let gone = dir.appendingPathComponent("gone.p8").path
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_PRIVATE_KEY_PATH=\(gone)\n", "4.env"),
                                            environment: [:]).failure, .privateKeyFileMissing(path: gone))
        let bad = try write("-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----\n", "bad.p8")
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_PRIVATE_KEY_PATH=\(bad.path)\n", "5.env"),
                                            environment: [:]).failure, .privateKeyInvalid)
        // 文言は足りない名前だけで、鍵を貼らせない。
        for problem in [AppStoreCredentialProblem.missingKeyID, .missingIssuerID, .missingPrivateKey, .privateKeyInvalid] {
            XCTAssertTrue(problem.message.contains("appstore-meta.env") || problem.message.contains(".p8"), problem.message)
        }
    }

    func testKeyPathMustBeAbsolute() throws {
        let env = try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_PRIVATE_KEY_PATH=keys/AuthKey.p8\n", "rel.env")
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: env, environment: [:]).failure, .privateKeyPathNotAbsolute(path: "keys/AuthKey.p8"))
        XCTAssertTrue(AppStoreCredentialProblem.privateKeyPathNotAbsolute(path: "x").message.contains("絶対パス"))
    }

    /// FIFO・フォルダは読まずに断る（開く時も読む時も待たない）。リンクは辿った先が通常のファイルなら読む。
    func testOnlyRegularFilesAreRead() throws {
        let fifo = dir.appendingPathComponent("fifo.env")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: fifo, environment: [:]).failure, .envFileUnreadable(path: fifo.path))
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: dir, environment: [:]).failure, .envFileUnreadable(path: dir.path))
        let keyFifo = dir.appendingPathComponent("key.p8")
        XCTAssertEqual(mkfifo(keyFifo.path, 0o600), 0)
        let env = try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_PRIVATE_KEY_PATH=\(keyFifo.path)\n", "k.env")
        XCTAssertEqual(AppStoreEnvFile.load(fileURL: env, environment: [:]).failure, .privateKeyFileUnreadable(path: keyFifo.path))

        let key = P256.Signing.PrivateKey()
        let real = try write(key.pemRepresentation, "real.p8")
        let link = dir.appendingPathComponent("link.p8")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linked = try write("ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_PRIVATE_KEY_PATH=\(link.path)\n", "l.env")
        XCTAssertNotNil(try? AppStoreEnvFile.load(fileURL: linked, environment: [:]).get())
    }

    /// 読み元は名前だけを出す。プロジェクトの .env などは見ない。
    func testSourceLabel() throws {
        let key = P256.Signing.PrivateKey()
        let p8 = try write(key.pemRepresentation, "s.p8")
        let env = try write("ASC_ISSUER_ID=ISS\nASC_PRIVATE_KEY_PATH=\(p8.path)\nOTHER_SECRET=x\n", "s.env")
        let settings = try AppStoreEnvFile.settings(fileURL: env, environment: ["ASC_KEY_ID": "SECRETKID"]).get()
        XCTAssertEqual(settings.source, AppStoreCredentialSource(environmentKeys: ["ASC_KEY_ID"], envFile: true))
        XCTAssertEqual(settings.source.label, "環境変数（ASC_KEY_ID） と ~/.claude/appstore-meta.env")
        XCTAssertFalse(settings.source.label.contains("SECRETKID"))
        XCTAssertEqual(AppStoreCredentialSource(envFile: true).label, "~/.claude/appstore-meta.env")
        for text in [String(describing: settings), String(reflecting: settings)] { XCTAssertFalse(text.contains("SECRETKID"), text) }
        let onlyEnv = try AppStoreEnvFile.settings(fileURL: dir.appendingPathComponent("none.env"),
                                                   environment: ["ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_PRIVATE_KEY": "x"]).get()
        XCTAssertFalse(onlyEnv.source.envFile)
    }

    func testCredentialsDoNotPrintSecrets() throws {
        let credentials = AppStoreCredentials(keyID: "SECRETKEYID", issuerID: "SECRETISSUER", privateKey: P256.Signing.PrivateKey())
        for text in [String(describing: credentials), String(reflecting: credentials), "\(credentials)"] {
            XCTAssertFalse(text.contains("SECRET"), text)
        }
        var dumped = ""
        dump(credentials, to: &dumped)
        XCTAssertFalse(dumped.contains("SECRET"), dumped)
    }
}

final class AppStoreJWTTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private var credentials: AppStoreCredentials { AppStoreCredentials(keyID: "ABC123DEFG", issuerID: "00000000-1111-2222-3333-444444444444", privateKey: key) }

    private func parts(_ token: String) throws -> (header: [String: Any], payload: [String: Any], signingInput: String, signature: Data) {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(pieces.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(AppStoreJWT.decodeBase64URL(pieces[0]))) as? [String: Any])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(AppStoreJWT.decodeBase64URL(pieces[1]))) as? [String: Any])
        return (header, payload, pieces[0] + "." + pieces[1], try XCTUnwrap(AppStoreJWT.decodeBase64URL(pieces[2])))
    }

    func testTokenShapeAndSignatureVerifiesWithPublicKey() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try AppStoreJWT.make(credentials: credentials, now: now)
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        let (header, payload, input, signature) = try parts(token)
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "ABC123DEFG")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        XCTAssertEqual(payload["iss"] as? String, "00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        let iat = try XCTUnwrap(payload["iat"] as? Int)
        let exp = try XCTUnwrap(payload["exp"] as? Int)
        XCTAssertEqual(iat, 1_800_000_000)
        XCTAssertGreaterThan(exp, iat)
        XCTAssertLessThanOrEqual(exp - iat, 20 * 60)
        // raw（r||s）の 64 バイトで、公開鍵で確かめられる。
        XCTAssertEqual(signature.count, 64)
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(key.publicKey.isValidSignature(ecdsa, for: Data(input.utf8)))
        XCTAssertFalse(P256.Signing.PrivateKey().publicKey.isValidSignature(ecdsa, for: Data(input.utf8)))
        XCTAssertFalse(key.publicKey.isValidSignature(ecdsa, for: Data((input + "x").utf8)))
    }

    func testLifetimeNeverExceedsTwentyMinutes() throws {
        let token = try AppStoreJWT.make(credentials: credentials, now: Date(timeIntervalSince1970: 1000), lifetime: 3600)
        let payload = try parts(token).payload
        XCTAssertEqual((payload["exp"] as? Int).map { $0 - 1000 }, 20 * 60)
        // 既定は appstore-plugin と同じ 10 分。
        let standard = try parts(AppStoreJWT.make(credentials: credentials, now: Date(timeIntervalSince1970: 1000))).payload
        XCTAssertEqual((standard["exp"] as? Int).map { $0 - 1000 }, 10 * 60)
    }

    /// 鍵はトークンを作る時だけ読み、Key ID か Issuer ID が替われば作り直す。
    func testCacheReadsKeyOnlyWhenMakingAndFollowsIDs() throws {
        var cache = AppStoreTokenCache()
        let start = Date(timeIntervalSince1970: 3_000_000)
        var reads = 0
        func load() -> Result<AppStoreCredentials, AppStoreCredentialProblem> {
            reads += 1
            return .success(credentials)
        }
        let first = try cache.token(keyID: "A", issuerID: "I", now: start, credentials: load)
        XCTAssertEqual(try cache.token(keyID: "A", issuerID: "I", now: start.addingTimeInterval(10), credentials: load), first)
        XCTAssertEqual(reads, 1)
        XCTAssertNotEqual(try cache.token(keyID: "B", issuerID: "I", now: start.addingTimeInterval(20), credentials: load), first)
        XCTAssertEqual(reads, 2)
        _ = try cache.token(keyID: "B", issuerID: "J", now: start.addingTimeInterval(30), credentials: load)
        XCTAssertEqual(reads, 3)
        XCTAssertThrowsError(try cache.token(keyID: "C", issuerID: "J", now: start.addingTimeInterval(40)) { .failure(.privateKeyInvalid) })
    }

    func testCacheReusesUntilNearExpiry() throws {
        var cache = AppStoreTokenCache()
        let start = Date(timeIntervalSince1970: 2_000_000)
        let first = try cache.token(credentials: credentials, now: start)
        XCTAssertEqual(try cache.token(credentials: credentials, now: start.addingTimeInterval(60)), first)
        let renewed = try cache.token(credentials: credentials, now: start.addingTimeInterval(AppStoreJWT.lifetime - 30))
        XCTAssertNotEqual(renewed, first)
        cache.clear()
        XCTAssertNotEqual(try cache.token(credentials: credentials, now: start.addingTimeInterval(AppStoreJWT.lifetime - 29)), renewed)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
