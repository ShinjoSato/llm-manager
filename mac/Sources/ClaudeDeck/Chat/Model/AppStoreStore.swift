import Foundation
import MonitorKit
import Observation

/// 取得 1 つ分の状態（前の値は取り直しの間も出しておく）。
struct AppStoreFetch<Value: Sendable>: Sendable {
    var value: Value?
    var fetchedAt: Date?
    var loading = false
    var failure: AppStoreFailure?
}

/// App Store Connect から読んだもの（アプリの一覧・版と審査・文面）の持ち手。アプリ全体で 1 つ。
/// 取るのはタブ・設定の欄を開いた時と「再読み込み」だけで、10 分の間は覚えた値を使う（定期の取得はしない）。
@MainActor
@Observable
final class AppStoreStore {
    static let shared = AppStoreStore(client: AppStoreClient())

    private(set) var apps = AppStoreFetch<[AppStoreApp]>()
    private(set) var overviews: [String: AppStoreFetch<AppStoreAppOverview>] = [:]
    private(set) var metadata: [String: AppStoreFetch<[AppStoreLocaleMetadata]>] = [:]
    /// 「再読み込み」の回数（開いている文面の取り直しの合図）。
    private(set) var reloadCount = 0

    @ObservationIgnored private let client: AppStoreClient
    @ObservationIgnored private var appsCache = AppStoreCache<String, [AppStoreApp]>()
    @ObservationIgnored private var overviewCache = AppStoreCache<String, AppStoreAppOverview>()
    @ObservationIgnored private var metadataCache = AppStoreCache<String, [AppStoreLocaleMetadata]>()
    /// 取り直しを押した後に届いた古い結果で上書きしないための番号。
    @ObservationIgnored private var generations: [String: Int] = [:]

    init(client: AppStoreClient) {
        self.client = client
    }

    func app(_ appId: String) -> AppStoreApp? {
        apps.value?.first { $0.id == appId }
    }

    static func metadataKey(versionId: String, appInfoId: String?) -> String { "\(versionId)|\(appInfoId ?? "-")" }

    func loadApps(force: Bool = false) {
        let key = "apps"
        if !force, apps.loading || appsCache.fresh(key) != nil { return }
        let generation = begin(key)
        apps.loading = true
        if force { apps.failure = nil }
        Task {
            let result: Result<[AppStoreApp], AppStoreFailure>
            do throws(AppStoreFailure) { result = .success(try await client.apps()) } catch { result = .failure(error) }
            guard generations[key] == generation else { return }
            apps.loading = false
            switch result {
            case .success(let list):
                let now = Date()
                appsCache.store(list, for: key, at: now)
                apps = AppStoreFetch(value: list, fetchedAt: now)
            case .failure(let failure):
                apps.failure = failure
            }
        }
    }

    func loadOverview(appId: String, force: Bool = false) {
        let key = "overview|\(appId)"
        if !force, overviews[appId]?.loading == true || overviewCache.fresh(appId) != nil { return }
        let generation = begin(key)
        var state = overviews[appId] ?? AppStoreFetch()
        state.loading = true
        if force { state.failure = nil }
        overviews[appId] = state
        Task {
            let result: Result<AppStoreAppOverview, AppStoreFailure>
            do throws(AppStoreFailure) { result = .success(try await client.overview(appId: appId)) } catch { result = .failure(error) }
            guard generations[key] == generation else { return }
            switch result {
            case .success(let overview):
                let now = Date()
                overviewCache.store(overview, for: appId, at: now)
                overviews[appId] = AppStoreFetch(value: overview, fetchedAt: now)
            case .failure(let failure):
                overviews[appId]?.loading = false
                overviews[appId]?.failure = failure
            }
        }
    }

    func loadMetadata(versionId: String, appInfoId: String?, primaryLocale: String?, force: Bool = false) {
        let key = Self.metadataKey(versionId: versionId, appInfoId: appInfoId)
        if !force, metadata[key]?.loading == true || metadataCache.fresh(key) != nil { return }
        let generation = begin("metadata|\(key)")
        var state = metadata[key] ?? AppStoreFetch()
        state.loading = true
        if force { state.failure = nil }
        metadata[key] = state
        Task {
            let result: Result<[AppStoreLocaleMetadata], AppStoreFailure>
            do throws(AppStoreFailure) {
                result = .success(try await client.metadata(versionId: versionId, appInfoId: appInfoId, primaryLocale: primaryLocale))
            } catch {
                result = .failure(error)
            }
            guard generations["metadata|\(key)"] == generation else { return }
            switch result {
            case .success(let list):
                let now = Date()
                metadataCache.store(list, for: key, at: now)
                metadata[key] = AppStoreFetch(value: list, fetchedAt: now)
            case .failure(let failure):
                metadata[key]?.loading = false
                metadata[key]?.failure = failure
            }
        }
    }

    /// 「再読み込み」: 鍵を読み直し、覚えた文面も捨てて取り直す（次に見た時に取る）。
    func reload(appIds: [String]) {
        metadataCache.removeAll()
        Task {
            await client.resetToken()
            loadApps(force: true)
            for appId in appIds { loadOverview(appId: appId, force: true) }
            reloadCount += 1
        }
    }

    private func begin(_ key: String) -> Int {
        let next = (generations[key] ?? 0) + 1
        generations[key] = next
        return next
    }
}
