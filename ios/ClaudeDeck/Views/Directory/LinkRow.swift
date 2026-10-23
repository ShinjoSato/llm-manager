import DeckCore
import SwiftUI

/// リンク 1 行（種類のアイコン・名前・接続先・メモ・ピン）。押すと Safari で開く（http / https だけ）。
struct LinkRow: View {
    let link: RemoteProjectLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        let url = link.openableURL
        Button {
            if let url { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: link.kind.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(url == nil ? DeckTheme.tertiary : DeckTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DeckTheme.inputSurface))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(link.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(url == nil ? DeckTheme.tertiary : DeckTheme.text)
                            .lineLimit(1)
                        if link.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(DeckTheme.tertiary)
                                .accessibilityLabel("ピン留め")
                        }
                        Spacer(minLength: 4)
                        Text(link.kind.label)
                            .font(.system(size: 11))
                            .foregroundStyle(DeckTheme.tertiary)
                    }
                    Text(link.hostLabel)
                        .font(DeckTheme.mono)
                        .foregroundStyle(DeckTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = link.note, !note.isEmpty {
                        Text(note)
                            .font(DeckTheme.caption)
                            .foregroundStyle(DeckTheme.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(url == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(url == nil ? "開けないリンクです" : "Safari で開きます")
        .accessibilityIdentifier("link-\(link.name)")
    }
}

/// プロジェクトの一覧（`GET /v1/projects`）の読み込みの様子。一覧が無い時は代わりに、ある時は上に添えて出す。
struct ProjectsStatusView: View {
    @Bindable var model: AppModel
    /// 読めた一覧に出すものが無い時の文言。
    let emptyTitle: String
    let emptyDetail: String
    /// 読めた一覧から出すものが無いか。
    let isEmpty: (RemoteProjectList) -> Bool

    var body: some View {
        if let projects = model.projects {
            if case .failed(let reason) = model.projectsStatus {
                InlineNotice(symbol: "exclamationmark.triangle", text: "一覧を取り直せませんでした（\(reason)）。前に読めた内容を出しています。")
            }
            if isEmpty(projects) {
                message(emptyTitle, emptyDetail, symbol: nil)
            }
        } else {
            switch model.projectsStatus {
            case .outdatedMac:
                message(AppModel.outdatedMacText, nil, symbol: "exclamationmark.arrow.circlepath")
                    .accessibilityIdentifier("projects-outdated")
            case .failed(let reason):
                message("一覧を読み込めませんでした（\(reason)）", "下に引っ張ると読み直します。", symbol: "exclamationmark.triangle")
            case .loading, .idle, .loaded:
                message(model.connection.isConnected ? "一覧を読み込んでいます…" : "Mac につながると一覧が出ます", nil, symbol: nil)
            }
        }
    }

    private func message(_ title: String, _ detail: String?, symbol: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(DeckTheme.permission) }
                Text(title).font(DeckTheme.body).foregroundStyle(DeckTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail).font(DeckTheme.caption).foregroundStyle(DeckTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
