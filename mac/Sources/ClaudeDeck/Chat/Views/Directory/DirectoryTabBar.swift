import MonitorKit
import SwiftUI

/// 詳細の見出しの下のタブの列（アイコン・名前・件数）。入りきらなければアイコンを外し、それでも入らなければ横にスクロールする。
struct DirectoryTabBar: View {
    struct Item: Identifiable, Equatable {
        let tab: DirectoryTab
        /// 分からない間（未走査）は nil で、数字を出さない。
        let count: Int?

        var id: DirectoryTab { tab }
    }

    let items: [Item]
    let selection: DirectoryTab
    let select: (DirectoryTab) -> Void

    static let height: CGFloat = 40

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsSymbols: true)
            row(showsSymbols: false)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { row(showsSymbols: false) }
                    .scrollIndicators(.never)
                    // 選んだタブが端に隠れたまま開かないよう見える所へ寄せる。
                    .onAppear { proxy.scrollTo(selection) }
                    .onChange(of: selection) { _, tab in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(tab) } }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .headerBackground()
    }

    private func row(showsSymbols: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                DirectoryTabButton(item: item, selected: item.tab == selection, showsSymbol: showsSymbols) {
                    select(item.tab)
                }
                .id(item.tab)
            }
        }
        // 縦は帯いっぱいにして、選んだタブの下線を帯の下線に重ねる。
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DirectoryTabButton: View {
    let item: DirectoryTabBar.Item
    let selected: Bool
    let showsSymbol: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsSymbol {
                    Image(systemName: item.tab.symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(item.tab.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                if let count = item.count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? ChatTheme.text : ChatTheme.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(ChatTheme.inputSurface))
                        .overlay(Capsule().stroke(ChatTheme.inputBorder, lineWidth: 0.5))
                }
            }
            .foregroundStyle(selected ? ChatTheme.heading : ChatTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !selected ? ChatTheme.selectedRow : .clear))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(ChatTheme.selectionInk).frame(height: 2).padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.count.map { "\(item.tab.label)（\($0) 件）" } ?? item.tab.label)
        .accessibilityLabel(item.count.map { "\(item.tab.label) \($0) 件" } ?? item.tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}
