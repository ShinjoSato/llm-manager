import AppKit
import MonitorKit
import SwiftUI

/// ブランチの図の寸法。
enum BranchGraphMetrics {
    static let rowHeight: CGFloat = 24
}

/// テーマのレーンの色（Canvas に渡すので、外観に頼らず今のテーマの値で引く）。
struct BranchGraphPalette: Equatable {
    let lanes: [Color]
    let surface: Color

    init(theme: DeckTheme) {
        lanes = theme.palette.graphLanes.map(Color.init(hex:))
        surface = Color(hex: theme.palette.stagePanel)
    }

    func lane(_ index: Int) -> Color { lanes.isEmpty ? .gray : lanes[index % lanes.count] }
}

/// 右パネルの「ブランチ」: 選択中のルームのフォルダの git の図。
struct StageBranchPanel: View {
    let model: ChatModel

    @State private var graph = BranchGraphModel()

    private var directory: String? { model.selectedRoom?.cwd }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { graph.show(directory: directory) }
            .onChange(of: directory) { _, next in graph.show(directory: next) }
            .onDisappear { graph.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch graph.phase {
        case .idle:
            placeholder(model.selectedRoom == nil
                        ? "ルームを選ぶと、そのフォルダのブランチの図をここで見られます"
                        : "このルームのフォルダが分かりません")
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository:
            placeholder("このフォルダは git のリポジトリではありません", detail: directory, retry: true)
        case .missingFolder:
            placeholder("このルームのフォルダが見つかりません", detail: directory, retry: true)
        case .noGit:
            placeholder(GitRunError.gitNotFound.message, retry: true)
        case .failed(let message):
            placeholder("ブランチを読めませんでした", detail: message, retry: true)
        case .loaded(let snapshot):
            BranchGraphView(graph: graph, snapshot: snapshot)
        }
    }

    private func placeholder(_ text: String, detail: String? = nil, retry: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22))
                .foregroundStyle(ChatTheme.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTheme.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if retry {
                Button { graph.reload() } label: {
                    Label("読み直す", systemImage: "arrow.clockwise")
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .inputFieldSurface(7)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 読み込めた図: 見出し（リポジトリ・今のブランチ・件数・読み直し）と、コミットの一覧。
private struct BranchGraphView: View {
    let graph: BranchGraphModel
    let snapshot: GitGraphSnapshot

    private var geometry: GitGraphGeometry { GitGraphGeometry(lanes: snapshot.maxWidth) }

    var body: some View {
        // Lazy な行は body の外で組まれ、そこでの読み取りは変化を拾わないので、テーマはここで読んで下へ渡す。
        let palette = BranchGraphPalette(theme: AppearanceSettings.shared.theme)
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            Rectangle().fill(ChatTheme.border).frame(height: 1)
            if snapshot.entries.isEmpty {
                Text("まだコミットがありません")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(palette: palette)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snapshot.location.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                    if snapshot.location.isWorktree {
                        Text("作業ツリー")
                            .font(.system(size: 10))
                            .foregroundStyle(ChatTheme.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5)).accessibilityHidden(true)
                    Text(snapshot.currentBranch ?? "HEAD（切り離し）")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            }
            Spacer(minLength: 4)
            if let failure = graph.refreshFailure {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTheme.permission)
                    .help("読み直せませんでした: \(failure)")
                    .accessibilityLabel("読み直せませんでした: \(failure)")
            }
            if graph.refreshing {
                ProgressView().controlSize(.mini)
            }
            Text("\(snapshot.entries.count) 件")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(ChatTheme.tertiary)
            Button { graph.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(ChatTheme.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .headerButtonHelp(name: "読み直す", detail: "ref が変わると自動で描き直します", busyStatus: nil)
        }
        .zIndex(1)
    }

    private func list(palette: BranchGraphPalette) -> some View {
        let known = Set(snapshot.entries.map(\.commit.hash))
        return ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.entries) { entry in
                            BranchGraphRowView(entry: entry, palette: palette, geometry: geometry,
                                               isHead: entry.commit.hash == snapshot.headOid,
                                               selected: graph.selected == entry.id, now: context.date) {
                                graph.toggle(entry.id)
                            }
                            .id(entry.id)
                            if graph.selected == entry.id {
                                BranchCommitDetailView(entry: entry, state: graph.details[entry.id], palette: palette,
                                                       geometry: geometry, known: known) { parent in
                                    graph.select(parent)
                                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(parent, anchor: .center) }
                                }
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if snapshot.hasMore && graph.canLoadMore {
            Button { graph.loadMore() } label: {
                Text("もっと見る（さらに \(GitRepositoryReader.limitStep) 件）")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .inputFieldSurface(7)
            }
            .buttonStyle(.plain)
            .disabled(graph.refreshing)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if snapshot.hasMore {
            Text("表示できるのは新しい \(snapshot.entries.count) 件までです")
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
    }
}

/// コミット 1 行: 線と点・ref の札・説明（1 行目）・相対の日付。作者と ID はホバーで出す。
private struct BranchGraphRowView: View {
    let entry: GitGraphEntry
    let palette: BranchGraphPalette
    let geometry: GitGraphGeometry
    let isHead: Bool
    let selected: Bool
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    private static let shownLabels = 2

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                BranchGraphCanvas(row: entry.row, palette: palette, geometry: geometry, isHead: isHead, isMerge: entry.commit.isMerge)
                    .frame(width: geometry.width, height: BranchGraphMetrics.rowHeight)
                labels
                Text(entry.commit.subject.isEmpty ? "（説明なし）" : entry.commit.subject)
                    .font(.system(size: 12, weight: isHead ? .semibold : .regular))
                    .foregroundStyle(entry.commit.subject.isEmpty ? ChatTheme.tertiary : ChatTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(GitDates.relative(entry.commit.authorDate, now: now))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(ChatTheme.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.trailing, 6)
            .frame(height: BranchGraphMetrics.rowHeight)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected || hovering ? ChatTheme.selectedRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var labels: some View {
        let shown = entry.labels.prefix(Self.shownLabels)
        ForEach(shown) { label in
            RefChip(label: label, color: label.kind == .tag ? ChatTheme.secondary : palette.lane(entry.row.color))
                .layoutPriority(2)
        }
        if entry.labels.count > Self.shownLabels {
            Text("+\(entry.labels.count - Self.shownLabels)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChatTheme.secondary)
                .fixedSize()
                .layoutPriority(2)
        }
    }

    private var tooltip: String {
        var lines = [entry.commit.subject]
        lines.append("\(entry.commit.authorName) · \(BranchDates.absolute(entry.commit.authorDate))")
        lines.append(entry.commit.shortHash + (entry.commit.isMerge ? "（マージ）" : ""))
        if !entry.labels.isEmpty { lines.append(entry.labels.map(\.fullText).joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        let refs = entry.labels.map(\.fullText).joined(separator: "、")
        return [refs, entry.commit.subject, entry.commit.authorName, GitDates.relative(entry.commit.authorDate, now: now)]
            .filter { !$0.isEmpty }.joined(separator: "、")
    }
}

/// ref の札（ローカルとリモートが同じなら雲の印を添えて 1 枚。今のブランチは濃く塗る）。
private struct RefChip: View {
    let label: GitRefLabel
    let color: Color

    private var symbol: String {
        switch label.kind {
        case .head: return "smallcircle.filled.circle"
        case .branch: return "arrow.triangle.branch"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            Text(label.compactName())
                .font(.system(size: 10.5, weight: label.isCurrent ? .bold : .medium))
                .lineLimit(1)
            if !label.remotes.isEmpty {
                Image(systemName: "cloud").font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(ChatTheme.text)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(label.isCurrent ? 0.32 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(label.isCurrent ? 1 : 0.55), lineWidth: label.isCurrent ? 1.4 : 1))
        .fixedSize()
    }
}

/// 1 行分の線と点。線は上端・点・下端を結び、列が替わる所は曲線で描く。
private struct BranchGraphCanvas: View {
    let row: GitGraphRow
    let palette: BranchGraphPalette
    let geometry: GitGraphGeometry
    let isHead: Bool
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            let height = size.height
            func y(_ anchor: GitGraphEdge.Anchor) -> CGFloat {
                switch anchor {
                case .top: return 0
                case .center: return height / 2
                case .bottom: return height
                }
            }
            for edge in row.edges {
                let start = CGPoint(x: geometry.x(edge.from), y: y(edge.fromAnchor))
                let end = CGPoint(x: geometry.x(edge.to), y: y(edge.toAnchor))
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let middle = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
                }
                context.stroke(path, with: .color(palette.lane(edge.color)), style: StrokeStyle(lineWidth: geometry.lineWidth, lineCap: .round))
            }
            let center = CGPoint(x: geometry.x(row.column), y: height / 2)
            let radius = geometry.dotRadius
            let color = palette.lane(row.color)
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            if isHead {
                context.fill(circle(radius + 1.6), with: .color(palette.surface))
                context.stroke(circle(radius + 1.6), with: .color(color), lineWidth: 2)
                context.fill(circle(radius * 0.6), with: .color(color))
            } else if isMerge {
                context.fill(circle(radius), with: .color(palette.surface))
                context.stroke(circle(radius), with: .color(color), lineWidth: geometry.lineWidth)
            } else {
                context.fill(circle(radius), with: .color(color))
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 詳細の左に、下へ続く線をそのまま伸ばす。
private struct BranchLaneGutter: View {
    let lanes: [GitGraphLane]
    let palette: BranchGraphPalette
    let geometry: GitGraphGeometry

    var body: some View {
        Canvas { context, size in
            for lane in lanes {
                var path = Path()
                let x = geometry.x(lane.column)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(palette.lane(lane.color)), lineWidth: geometry.lineWidth)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 押したコミットの詳細: 本文・作者・日時・親・変わったファイル・ID のコピー。
private struct BranchCommitDetailView: View {
    let entry: GitGraphEntry
    let state: BranchGraphModel.DetailState?
    let palette: BranchGraphPalette
    let geometry: GitGraphGeometry
    let known: Set<String>
    let onSelectParent: (String) -> Void

    /// 一度に描くファイルの数（大きなコミットでも欄を重くしない）。
    private static let shownFiles = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .loaded(let detail): content(detail)
            case .failed(let message):
                Text(message).font(ChatTheme.caption).foregroundStyle(ChatTheme.error)
            case .loading, nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.codeSurface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatTheme.border, lineWidth: 1))
        .padding(.vertical, 4)
        .padding(.leading, geometry.width + 5)
        .background(alignment: .leading) {
            BranchLaneGutter(lanes: entry.row.continuing, palette: palette, geometry: geometry).frame(width: geometry.width)
        }
    }

    @ViewBuilder
    private func content(_ detail: GitCommitDetail) -> some View {
        Text(detail.message.isEmpty ? "（説明なし）" : detail.message)
            .font(.system(size: 12))
            .foregroundStyle(ChatTheme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 3) {
            meta("作者", "\(detail.authorName) <\(detail.authorEmail)>")
            meta("日時", BranchDates.absolute(detail.authorDate))
            if detail.committerName != detail.authorName || detail.committerEmail != detail.authorEmail {
                meta("コミッター", "\(detail.committerName) · \(BranchDates.absolute(detail.commitDate))")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label("ID")
                Text(detail.hash)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ChatTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                CopyHashButton(hash: detail.hash)
            }
            if !detail.parents.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    label("親")
                    ForEach(detail.parents, id: \.self) { parent in
                        Button { onSelectParent(parent) } label: {
                            Text(String(parent.prefix(7)))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(known.contains(parent) ? ChatTheme.link : ChatTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!known.contains(parent))
                        .help(known.contains(parent) ? "このコミットへ移る" : "読み込んだ範囲の外です")
                    }
                }
            }
        }
        files(detail)
    }

    @ViewBuilder
    private func files(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(detail.parents.count > 1
                 ? "変わったファイル \(detail.files.count) 件（最初の親との差分）"
                 : "変わったファイル \(detail.files.count) 件")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatTheme.secondary)
            ForEach(detail.files.prefix(Self.shownFiles)) { file in
                FileChangeRow(file: file)
            }
            if detail.files.count > Self.shownFiles {
                Text("ほか \(detail.files.count - Self.shownFiles) 件")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTheme.tertiary)
            }
            if detail.filesTruncated {
                Text("一覧が大きすぎるため途中までです")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
    }

    private func meta(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            label(name)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func label(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(ChatTheme.tertiary)
            .frame(width: 56, alignment: .leading)
    }
}

/// 変わったファイル 1 行（状態の文字・パス。名前の変更は元 → 先）。
private struct FileChangeRow: View {
    let file: GitFileChange

    private var tint: Color {
        switch file.status {
        case .added: return ChatTheme.working
        case .deleted: return ChatTheme.error
        case .renamed, .copied: return ChatTheme.permission
        case .modified, .typeChanged, .other: return ChatTheme.waiting
        }
    }

    private var name: String {
        switch file.status {
        case .added: return "追加"
        case .modified: return "変更"
        case .deleted: return "削除"
        case .renamed: return "名前の変更"
        case .copied: return "複製"
        case .typeChanged: return "種類の変更"
        case .other: return "その他"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(name): \(file.oldPath.map { "\($0) → " } ?? "")\(file.path)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(file.path)")
    }
}

/// ID をクリップボードへ写す（写したら少しの間だけ印を替える）。
private struct CopyHashButton: View {
    let hash: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hash, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5))
                .foregroundStyle(copied ? ChatTheme.working : ChatTheme.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "コピーしました" : "ID をコピー")
        .accessibilityLabel(copied ? "コピーしました" : "ID をコピー")
    }
}

enum BranchDates {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    static func absolute(_ date: Date) -> String { formatter.string(from: date) }
}
