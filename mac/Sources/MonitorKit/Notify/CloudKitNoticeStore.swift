import CloudKit
import Foundation
import Security

/// iCloud（CloudKit）を使えるか。エンタイトルメントが無いまま CKContainer を作るとプロセスが落ちるので、先に確かめる。
public enum CloudKitAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public static let missingEntitlementReason =
        "この起動では iCloud を使えません（swift run や ad-hoc 署名の .app には iCloud のエンタイトルメントが無いため）。"
        + "プロビジョニングプロファイルを用意して mac/scripts/bundle.sh で作った .app（Apple Development 署名）で使えます。"

    /// 署名に CloudKit と共有コンテナのエンタイトルメントが入っているか。
    public static func entitlementsPresent() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
        let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
        return matches(services: services, containers: containers)
    }

    static func matches(services: [String]?, containers: [String]?) -> Bool {
        (services ?? []).contains("CloudKit") && (containers ?? []).contains(AttentionNoticeSchema.containerIdentifier)
    }

    public static func current() -> CloudKitAvailability {
        entitlementsPresent() ? .available : .unavailable(missingEntitlementReason)
    }
}

/// 失敗の理由を短い日本語にする（画面に小さく出す）。
public struct CloudKitNoticeError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) { self.message = message }

    static func from(_ error: Error) -> CloudKitNoticeError {
        guard let ck = error as? CKError else { return CloudKitNoticeError(error.localizedDescription) }
        return from(code: ck.code)
    }

    static func from(code: CKError.Code) -> CloudKitNoticeError {
        switch code {
        case .notAuthenticated: return CloudKitNoticeError("この Mac で iCloud にサインインしていません")
        case .networkUnavailable, .networkFailure: return CloudKitNoticeError("ネットワークにつながっていません")
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return CloudKitNoticeError("iCloud が混み合っています")
        case .quotaExceeded: return CloudKitNoticeError("iCloud の容量が足りません")
        case .badContainer, .missingEntitlement, .permissionFailure:
            return CloudKitNoticeError("iCloud コンテナを使えません（登録・署名を確かめてください）")
        default: return CloudKitNoticeError("iCloud に書けませんでした（コード \(code.rawValue)）")
        }
    }
}

/// 知らせを自分の iCloud のプライベート DB（既定のゾーン）に置く。
public final class CloudKitNoticeStore: AttentionNoticeStore, @unchecked Sendable {
    private let database: CKDatabase

    /// `CloudKitAvailability.current() == .available` を確かめてから作る。
    public init(containerIdentifier: String = AttentionNoticeSchema.containerIdentifier) {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    public func save(_ notice: AttentionNotice) async throws {
        do {
            let result = try await database.modifyRecords(saving: [Self.record(for: notice)], deleting: [], savePolicy: .allKeys)
            _ = try result.saveResults[CKRecord.ID(recordName: notice.recordName)]?.get()
        } catch {
            throw CloudKitNoticeError.from(error)
        }
    }

    public func delete(recordName: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw CloudKitNoticeError.from(error)
        }
    }

    public static func record(for notice: AttentionNotice) -> CKRecord {
        let record = CKRecord(recordType: AttentionNoticeSchema.recordType, recordID: CKRecord.ID(recordName: notice.recordName))
        for (key, value) in AttentionNoticeSchema.fields(of: notice) {
            switch value {
            case .string(let text): record[key] = text as CKRecordValue
            case .int(let number): record[key] = number as CKRecordValue
            case .strings(let list): record[key] = list as CKRecordValue
            }
        }
        return record
    }
}
