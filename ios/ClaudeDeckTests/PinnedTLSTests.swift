import DeckCore
import Network
import Security
import XCTest

/// アプリの中（ATS の設定が効く所）で、自己署名の TLS の相手に指紋だけで繋がるかを確かめる。
final class PinnedTLSTests: XCTestCase {
    /// 試験用の自己署名の証明書と鍵（PKCS#12・パスワード test）。指紋は下の `pin`。
    private static let p12 = Data(base64Encoded: "MIIDkgIBAzCCA1AGCSqGSIb3DQEHAaCCA0EEggM9MIIDOTCCAi8GCSqGSIb3DQEHBqCCAiAwggIcAgEAMIICFQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQICc+h7db+QbsCAggAgIIB6Lch2jmVTDUXA6XAHtBov4uwN6DGlQIBrfVXsmAvN8EoKo5PeJepoDcj0GOqvWtDycyKJOGMO+BaSKn5j3g4I718ihnQOqXRevlTKw4FXDx4ENMOKq5HCmyz0+Dd88ktRhpraue213RbW3hHv/NiTiPwoEKanxeOBcmvFXfT3yqPx1K6ZRWD58Z3a4Pl90IsH8jWZdb4v5FtyTohXiWG9YNrqGzs5wciys0xPTwQjl+zus60JaHmEin6+GITMuU2VFANlh0+SGJP5YPgBn5Sb4DxI52UFGkWR4he+LLK8lD2UrQza0wxZwL3cJypfHvhEllLif4DF56aE1eDX17yMSGP4uboUQY+rd4zF6sODQmJEibhEpgcwoSHHiHmOrq2YVplJuOizJ/d6i0Sg84cfsFRLySnH40E1gSJfN7liyC4q5BSGOEGMbOBMmHPxNElX40e5M+wBl/tEBmYp3gCtYzdP5CBqxuZ3wzyQ2D7QBrAKs8lbkNDbDaABhPiLUJcTGbvOfHu1c+n47FfYkJy9/CV/mo6SSntA6yyLcXaHECpKt94R2ym/Ol63H9O06HUMs5CycYi1QxCk7xu7WOtHNdajtbwBJ5NeAEtMSMrrdsx+qg1I3umZh+QIa7iL/eT0VtAZ9R7kTmMMIIBAgYJKoZIhvcNAQcBoIH0BIHxMIHuMIHrBgsqhkiG9w0BDAoBAqCBtDCBsTAcBgoqhkiG9w0BDAEDMA4ECPETA1vg0NupAgIIAASBkM70hdjTYwjxBMaWkk2AgjVz0kLTBcRA+/psPUWLEqOnO2mRxqB0NwB9Am7s8ml7SFrh3IBrT7Rewtz//BryfEA/asSyUw4Apy9zE7kpmkz/+OzAy7+HoST5K2V7Im2zP038oetd9NgGbZxN9HiSO7WIfKb8ZVCGmA/TGfgHDPmi42CllXkRMbDsvH0MYpY3YDElMCMGCSqGSIb3DQEJFTEWBBSy20OzIO76pOZQo0zPsx2PJaXkXTA5MCEwCQYFKw4DAhoFAAQU2H/7BxcM5ROhP1WZAuY9lnAVIacEECEykTRjK4I/ZcnwkAn65SgCAggA")!
    private static let pin = "fe23391bbc2e3fbe7d3deb5e88a700c840462100a98fc52bbd175ba524787fce"

    private var listener: NWListener!
    private var port = 0

    override func setUp() async throws {
        var items: CFArray?
        let status = SecPKCS12Import(Self.p12 as CFData, [kSecImportExportPassphrase as String: "test"] as CFDictionary, &items)
        XCTAssertEqual(status, errSecSuccess)
        let first = try XCTUnwrap((items as? [[String: Any]])?.first)
        let identity = first[kSecImportItemIdentity as String] as! SecIdentity
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in Self.serve(connection) }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        port = Int(try XCTUnwrap(listener.port).rawValue)
    }

    override func tearDown() {
        listener?.cancel()
    }

    /// `/v1/info` だけを返す小さな相手（認証の中身は見ない）。
    private static func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { received.append(data) }
                if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let info = RemoteInfo(serverName: "tls-test", device: RemoteDevice(id: "d", name: "iPhone", pairedAt: 0, lastUsedAt: nil))
                    let body = try! JSONEncoder().encode(info)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    func testPinnedSelfSignedServerIsReachableFromTheApp() async throws {
        let client = RemoteClient(host: "127.0.0.1", port: port, pin: Self.pin, token: "t")
        defer { client.invalidate() }
        let info = try await client.info()
        XCTAssertEqual(info.serverName, "tls-test")
    }

    func testOtherPinIsRefused() async throws {
        let client = RemoteClient(host: "127.0.0.1", port: port, pin: String(repeating: "1", count: 64), token: "t")
        defer { client.invalidate() }
        do {
            _ = try await client.info()
            XCTFail("指紋が違えば繋がらない")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .pinMismatch)
        }
    }
}
