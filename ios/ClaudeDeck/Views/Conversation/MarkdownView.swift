import SwiftUI
import DeckCore

/// 解析結果を本文ごとに覚えておく。スクロールで吹き出しが作り直されても同じ本文は解析し直さない。
@MainActor
enum MarkdownCache {
    private final class BlocksBox {
        let blocks: [ChatMarkdown.Block]
        init(_ blocks: [ChatMarkdown.Block]) { self.blocks = blocks }
    }

    private final class InlineBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let blockCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 1000
        cache.totalCostLimit = 32 << 20
        return cache
    }()

    private static let inlineCache: NSCache<NSString, InlineBox> = {
        let cache = NSCache<NSString, InlineBox>()
        cache.countLimit = 8000
        cache.totalCostLimit = 32 << 20
        return cache
    }()

    static func blocks(_ text: String) -> [ChatMarkdown.Block] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.blocks }
        let blocks = ChatMarkdown.blocks(text)
        blockCache.setObject(BlocksBox(blocks), forKey: key, cost: text.utf16.count)
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let value = ChatMarkdown.inline(text)
        inlineCache.setObject(InlineBox(value), forKey: key, cost: text.utf16.count)
        return value
    }
}

/// Claude の返答本文。ブロックごとに SwiftUI で描く（選択・コピーは呼び出し側の `.textSelection` に任せる）。
struct MarkdownView: View {
    let text: String

    var body: some View {
        MarkdownBlocks(blocks: MarkdownCache.blocks(text), depth: 0)
            .tint(DeckTheme.waiting)
    }
}

private struct MarkdownBlocks: View {
    let blocks: [ChatMarkdown.Block]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: depth == 0 ? 10 : 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownCache.inline(text))
                .font(DeckTheme.body)
                .foregroundStyle(DeckTheme.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(MarkdownCache.inline(text))
                .font(Self.headingFont(level))
                .foregroundStyle(DeckTheme.heading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, depth == 0 ? 4 : 0)
        case .code(_, let code):
            MarkdownCodeBlock(code: code)
        case .list(let ordered, let start, let items):
            MarkdownList(ordered: ordered, start: start, items: items, depth: depth)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DeckTheme.secondary.opacity(0.45))
                    .frame(width: 3)
                // 自分自身を入れ子にするので型を消す（不透明型が自己参照にならないため）。
                AnyView(MarkdownBlocks(blocks: inner, depth: depth + 1))
                    .opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTable(table: table)
        case .rule:
            Rectangle()
                .fill(DeckTheme.claudeBubbleBorder)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 19, weight: .bold)
        case 2: return .system(size: 16.5, weight: .bold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }
}

private struct MarkdownCodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(DeckTheme.mono)
                .foregroundStyle(DeckTheme.text)
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.codeSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeckTheme.border))
    }
}

private struct MarkdownList: View {
    let ordered: Bool
    let start: Int
    let items: [ChatMarkdown.ListItem]
    let depth: Int

    var body: some View {
        let digits = String(start + max(items.count - 1, 0)).count
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(start + index)." : bullet)
                        .font(ordered ? DeckTheme.body.monospacedDigit() : DeckTheme.body)
                        .foregroundStyle(DeckTheme.secondary)
                        .frame(minWidth: ordered ? CGFloat(digits) * 8.5 + 6 : 10, alignment: .trailing)
                    AnyView(MarkdownBlocks(blocks: item.blocks, depth: depth + 1))
                }
            }
        }
    }

    private var bullet: String {
        ["•", "◦", "▪︎"][depth % 3]
    }
}

/// 表。列幅は中身に合わせ、長いセルは折り返す。吹き出しより広い時だけ横スクロールにする。
private struct MarkdownTable: View {
    let table: ChatMarkdown.Table

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: true) { grid }
        }
    }

    private var grid: some View {
        let columns = table.header.count
        return MarkdownTableLayout(columns: columns, maxColumnWidth: 260) {
            ForEach(0..<columns, id: \.self) { column in
                cell(table.header[column], column: column, row: -1)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
                ForEach(0..<columns, id: \.self) { column in
                    cell(column < cells.count ? cells[column] : "", column: column, row: row)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeckTheme.border))
    }

    private func cell(_ text: String, column: Int, row: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        let frameAlignment: Alignment = switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
        let textAlignment: TextAlignment = switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownCache.inline(text))
            .font(row < 0 ? DeckTheme.body.weight(.semibold) : DeckTheme.body)
            .foregroundStyle(row < 0 ? DeckTheme.heading : DeckTheme.text)
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .background(row < 0 ? DeckTheme.codeSurface : (row % 2 == 1 ? DeckTheme.background.opacity(0.35) : Color.clear))
            .overlay(alignment: .bottom) { Rectangle().fill(DeckTheme.border).frame(height: 1) }
            .overlay(alignment: .trailing) {
                if column < table.header.count - 1 { Rectangle().fill(DeckTheme.border).frame(width: 1) }
            }
    }
}

/// 行優先で並んだセルを、列ごとに最も広いセル（上限あり）の幅で揃え、行ごとに最も高いセルの高さで揃える。
struct MarkdownTableLayout: Layout {
    let columns: Int
    let maxColumnWidth: CGFloat

    struct Metrics {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Metrics? { nil }

    func updateCache(_ cache: inout Metrics?, subviews: Subviews) { cache = nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) -> CGSize {
        let m = metrics(subviews, &cache)
        return CGSize(width: m.widths.reduce(0, +), height: m.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) {
        let m = metrics(subviews, &cache)
        var y = bounds.minY
        for row in m.heights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: m.widths[column], height: m.heights[row]))
                x += m.widths[column]
            }
            y += m.heights[row]
        }
    }

    private func metrics(_ subviews: Subviews, _ cache: inout Metrics?) -> Metrics {
        if let cache { return cache }
        guard columns > 0 else { return Metrics(widths: [], heights: []) }
        let rows = (subviews.count + columns - 1) / columns
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(ideal.rounded(.up), maxColumnWidth))
        }
        var heights = Array(repeating: CGFloat(0), count: rows)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil))
            heights[index / columns] = max(heights[index / columns], size.height.rounded(.up))
        }
        let result = Metrics(widths: widths, heights: heights)
        cache = result
        return result
    }
}
