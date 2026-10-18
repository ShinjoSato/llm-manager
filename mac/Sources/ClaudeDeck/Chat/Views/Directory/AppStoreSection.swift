import AppKit
import MonitorKit
import SwiftUI

/// ディレクトリの詳細の「App Store」: 紐づけたアプリごとに版の状態・審査の提出・ロケールごとの文面を App Store Connect から読んで出す（読むだけ）。
struct AppStoreSection: View {
    let project: ManagedProject

    private var store: AppStoreStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SectionTitle(name: "App Store", count: project.appStoreApps.count)
                Spacer(minLength: 8)
                HeaderButton(symbol: "arrow.clockwise", name: "再読み込み",
                             detail: "App Store Connect から取り直す（鍵も読み直す）",
                             busyStatus: busy ? "取得中" : nil) {
                    store.reload(appIds: validIds)
                }
            }
            .zIndex(1)
            if let failure = store.apps.failure, case .credentials = failure {
                AppStoreNotice(text: failure.message, color: ChatTheme.error)
            }
            // 同じ appId が重なって書かれていても崩れないよう並びの番号で見分け、appId が替われば中の選択を持ち越さない。
            ForEach(Array(project.appStoreApps.enumerated()), id: \.offset) { _, link in
                AppStoreAppCard(link: link, hidesCredentialFailure: store.apps.failure.map(isCredentials) ?? false)
                    .id(link.appId)
            }
            SectionNote("読むだけです（書き換え・審査への提出は appstore-plugin の skill で行います）。鍵は \(AppStoreEnvFile.displayPath) から読みます。取った内容は 10 分覚えておき、「再読み込み」で取り直します。")
        }
        .detailCard()
        .task(id: project.appStoreApps) {
            store.loadApps()
            for appId in validIds { store.loadOverview(appId: appId) }
        }
    }

    private var validIds: [String] {
        var seen = Set<String>()
        return project.appStoreApps.map(\.appId).filter { AppStoreRequest.isAppID($0) && seen.insert($0).inserted }
    }

    private var busy: Bool {
        store.apps.loading || validIds.contains { store.overviews[$0]?.loading == true }
    }

    private func isCredentials(_ failure: AppStoreFailure) -> Bool {
        if case .credentials = failure { return true }
        return false
    }
}

/// アプリ 1 つ分: 見出し（名前・appId・バンドル ID）・版と審査・文面。
private struct AppStoreAppCard: View {
    let link: AppStoreAppLink
    let hidesCredentialFailure: Bool

    private var store: AppStoreStore { .shared }

    var body: some View {
        let app = store.app(link.appId)
        let fetch = store.overviews[link.appId]
        VStack(alignment: .leading, spacing: 10) {
            header(app: app, fetch: fetch)
            if !AppStoreRequest.isAppID(link.appId) {
                AppStoreNotice(text: AppStoreFailure.invalidRequest.message, color: ChatTheme.error)
            } else if let overview = fetch?.value {
                if let failure = fetch?.failure { AppStoreNotice(text: failure.message, color: ChatTheme.error) }
                AppStoreStatusBlock(overview: overview)
                AppStoreMetadataBlock(overview: overview, primaryLocale: app?.primaryLocale)
            } else if let failure = fetch?.failure {
                if !(hidesCredentialFailure && isCredentials(failure)) {
                    AppStoreNotice(text: failure.message, color: ChatTheme.error)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inputFieldSurface(10)
    }

    private func header(app: AppStoreApp?, fetch: AppStoreFetch<AppStoreAppOverview>?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(link.name.isEmpty ? (app?.name ?? link.appId) : link.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ChatTheme.heading)
                .lineLimit(1)
            if let app, app.name != link.name {
                Text(app.name).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary).lineLimit(1)
            }
            Text(app.map { "\($0.bundleId) · \(link.appId)" } ?? link.appId)
                .font(ChatTheme.mono)
                .foregroundStyle(ChatTheme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if fetch?.loading == true {
                ProgressView().controlSize(.mini)
            } else if let at = fetch?.fetchedAt {
                Text("取得 \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTheme.tertiary)
                    .help("取得した時刻（10 分の間はこの結果を出します）")
            }
        }
    }

    private func isCredentials(_ failure: AppStoreFailure) -> Bool {
        if case .credentials = failure { return true }
        return false
    }
}

/// 版の状態（プラットフォームごとの最新・公開中）と、審査の提出の新しい 3 件。
private struct AppStoreStatusBlock: View {
    let overview: AppStoreAppOverview

    var body: some View {
        let platforms = overview.platforms
        VStack(alignment: .leading, spacing: 6) {
            if platforms.isEmpty { SectionNote("版がまだありません") }
            ForEach(platforms) { summary in
                if platforms.count > 1 || summary.platform != "IOS" {
                    Text(AppStoreStates.platformLabel(summary.platform)).sectionLabelStyle()
                }
                row("最新の版", version: summary.latest)
                if let live = summary.live {
                    row("公開中の版", version: live)
                } else if !summary.latest.isLive {
                    labeled("公開中の版") { Text("なし").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary) }
                }
            }
            let submissions = Array(overview.submissions.prefix(3))
            labeled("審査の提出") {
                if submissions.isEmpty {
                    Text("なし").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(submissions) { submission in
                            HStack(spacing: 6) {
                                AppStoreStateChip(label: AppStoreStates.submissionLabel(submission.state),
                                                  tone: AppStoreStates.submissionTone(submission.state), raw: submission.state)
                                Text(submissionDetail(submission, showsPlatform: platforms.count > 1))
                                    .font(ChatTheme.caption)
                                    .foregroundStyle(ChatTheme.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, version: AppStoreVersion) -> some View {
        labeled(title) {
            HStack(spacing: 6) {
                Text(version.versionString.isEmpty ? "-" : version.versionString)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(ChatTheme.text)
                    .textSelection(.enabled)
                AppStoreStateChip(label: AppStoreStates.versionLabel(version.state),
                                  tone: AppStoreStates.versionTone(version.state), raw: version.state)
                if let date = version.createdDate {
                    Text("作成 \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundStyle(ChatTheme.tertiary)
                }
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .frame(width: 84, alignment: .leading)
            content()
        }
    }

    private func submissionDetail(_ submission: AppStoreReviewSubmission, showsPlatform: Bool) -> String {
        var parts: [String] = []
        if showsPlatform, let platform = submission.platform { parts.append(AppStoreStates.platformLabel(platform)) }
        if let date = submission.submittedDate {
            parts.append("提出 \(date.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("未提出")
        }
        return parts.joined(separator: " · ")
    }
}

/// 状態の印（日本語の名前・ホバーで原文）。
private struct AppStoreStateChip: View {
    let label: String
    let tone: AppStoreStateTone
    let raw: String?

    var body: some View {
        Text(label)
            .statusCapsule(color)
            .help(raw ?? "")
    }

    private var color: Color {
        switch tone {
        case .editing: return ChatTheme.secondary
        case .waiting: return ChatTheme.waiting
        case .inReview: return ChatTheme.permission
        case .rejected: return ChatTheme.error
        case .pendingRelease: return ChatTheme.link
        case .live: return ChatTheme.working
        case .inactive, .unknown: return ChatTheme.tertiary
        }
    }
}

/// 文面: 版（最新・公開中）とロケールを選んで、欄ごとに文字数と上限を添えて出す。
private struct AppStoreMetadataBlock: View {
    let overview: AppStoreAppOverview
    let primaryLocale: String?

    @State private var versionId: String?
    @State private var locale: String?

    private var store: AppStoreStore { .shared }

    var body: some View {
        let choices = overview.platforms.flatMap(\.metadataVersions)
        let version = choices.first { $0.id == versionId } ?? choices.first
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 2)
            if let version {
                let info = AppStoreVersions.appInfo(for: version, in: overview.appInfos)
                let key = AppStoreStore.metadataKey(versionId: version.id, appInfoId: info?.id)
                let fetch = store.metadata[key]
                HStack(spacing: 8) {
                    Text("文面").sectionLabelStyle()
                    if choices.count > 1 {
                        Picker("版", selection: Binding(get: { version.id }, set: { versionId = $0 })) {
                            ForEach(choices) { choice in
                                Text(versionTitle(choice, showsPlatform: overview.platforms.count > 1)).tag(choice.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(versionTitle(version, showsPlatform: false)).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                    }
                    if let list = fetch?.value, !list.isEmpty {
                        let current = list.first { $0.locale == locale } ?? list[0]
                        Picker("ロケール", selection: Binding(get: { current.locale }, set: { locale = $0 })) {
                            ForEach(list) { item in
                                Text(item.overLimitFields.isEmpty ? item.locale : "\(item.locale)  ⚠︎").tag(item.locale)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    if fetch?.loading == true { ProgressView().controlSize(.mini) }
                }
                content(fetch)
                    .task(id: "\(key)|\(store.reloadCount)") {
                        store.loadMetadata(versionId: version.id, appInfoId: info?.id, primaryLocale: primaryLocale)
                    }
            } else {
                SectionNote("文面を見られる版がありません")
            }
        }
    }

    @ViewBuilder
    private func content(_ fetch: AppStoreFetch<[AppStoreLocaleMetadata]>?) -> some View {
        if let list = fetch?.value {
            if let failure = fetch?.failure { AppStoreNotice(text: failure.message, color: ChatTheme.error) }
            if list.isEmpty {
                SectionNote("この版にはロケールの文面がありません")
            } else {
                let current = list.first { $0.locale == locale } ?? list[0]
                let over = current.overLimitFields
                if !over.isEmpty {
                    AppStoreNotice(text: "上限を超えています: " + over.map(\.label).joined(separator: "・"), color: ChatTheme.error)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AppStoreMetadataField.allCases) { field in
                        AppStoreFieldRow(field: field, value: current.value(field))
                    }
                }
            }
        } else if let failure = fetch?.failure {
            AppStoreNotice(text: failure.message, color: ChatTheme.error)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 30)
        }
    }

    private func versionTitle(_ version: AppStoreVersion, showsPlatform: Bool) -> String {
        let platform = showsPlatform ? "\(AppStoreStates.platformLabel(version.platform)) " : ""
        return "\(platform)\(version.versionString)（\(AppStoreStates.versionLabel(version.state))）"
    }
}

/// 欄 1 つ: 名前・文字数 / 上限（超えたら赤）・本文（長いものは畳める）。URL は押すとブラウザで開く。
private struct AppStoreFieldRow: View {
    let field: AppStoreMetadataField
    let value: String?
    @State private var expanded = false

    private static let foldLength = 280

    var body: some View {
        let count = AppStoreMetadataField.count(value)
        let over = field.isOver(value)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(field.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(ChatTheme.secondary)
                if let limit = field.limit {
                    Text("\(count) / \(limit)")
                        .font(.system(size: 11, weight: over ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(over ? ChatTheme.error : ChatTheme.tertiary)
                    if over {
                        Label("上限超え", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChatTheme.error)
                    }
                }
                if let value, !field.isURL, value.count > Self.foldLength {
                    Button(expanded ? "畳む" : "全文") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(ChatTheme.link)
                }
            }
            text(value)
        }
    }

    @ViewBuilder
    private func text(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            if field.isURL {
                if let url = ProjectLinks.url(from: value) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text(value).font(ChatTheme.caption).foregroundStyle(ChatTheme.link).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("ブラウザで開く: \(value)")
                } else {
                    Text(value).font(ChatTheme.caption).foregroundStyle(ChatTheme.text).textSelection(.enabled)
                }
            } else {
                Text(expanded || value.count <= Self.foldLength ? value : String(value.prefix(Self.foldLength)) + "…")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else {
            Text("未入力").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
        }
    }
}

private struct AppStoreNotice: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(color)
    }
}
