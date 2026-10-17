import DeckCore
import PhotosUI
import SwiftUI

/// 入力欄。ホスト中のセッションは端末の入力欄へ、外部セッションは伝言として送る。
struct ComposerBar: View {
    @Bindable var model: AppModel
    let room: RemoteRoom
    @FocusState private var focused: Bool
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        let relay = room.send.mode == .relay
        let reason = disabledReason
        let text = Binding(get: { model.drafts[room.id] ?? "" }, set: { model.drafts[room.id] = $0 })
        let sending = model.inFlight.contains(room.id)
        let canSend = reason == nil && !sending && model.hasSomethingToSend(room.id)
        let images = model.images(room.id)
        let preparing = model.preparingImages[room.id] ?? 0
        VStack(alignment: .leading, spacing: 6) {
            if relay {
                HStack(spacing: 6) {
                    Text("伝言")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DeckTheme.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(DeckTheme.permission))
                    Text("受け手には別セッションからのメッセージとして届きます")
                        .font(DeckTheme.caption)
                        .foregroundStyle(DeckTheme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.leading, 4)
            }
            if let reason, !text.wrappedValue.isEmpty || !images.isEmpty {
                Text(reason).font(DeckTheme.caption).foregroundStyle(DeckTheme.permission).padding(.leading, 4)
            }
            if !images.isEmpty || preparing > 0 {
                ImageStrip(images: images, preparing: preparing) { model.removeImage($0, from: room.id) }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if model.canAttachImages(room) {
                    photoPicker(disabled: reason != nil || sending)
                }
                TextField("", text: text, prompt: Text(reason ?? (relay ? "伝言を送信" : "メッセージを送信")).foregroundStyle(DeckTheme.tertiary),
                          axis: .vertical)
                    .font(DeckTheme.body)
                    .foregroundStyle(DeckTheme.text)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(reason != nil)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("composer")
                Button { model.send(room) } label: {
                    Group {
                        if sending {
                            ProgressView().tint(DeckTheme.onAccent)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        }
                    }
                    .foregroundStyle(DeckTheme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(relay ? DeckTheme.permission : DeckTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend || sending ? 1 : 0.4)
                .padding(.bottom, 3)
                .accessibilityLabel(relay ? "伝言を送信" : "送信")
                .accessibilityIdentifier("send")
            }
            .padding(.leading, model.canAttachImages(room) ? 6 : 14)
            .padding(.trailing, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 20).fill(DeckTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(relay ? DeckTheme.permission.opacity(0.6) : DeckTheme.inputBorder,
                        style: StrokeStyle(lineWidth: 1, dash: relay ? [5, 4] : [])))
            .opacity(reason == nil ? 1 : 0.7)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(DeckTheme.background)
        .overlay(alignment: .top) { Rectangle().fill(DeckTheme.border).frame(height: 1) }
    }

    /// 写真の選択（複数可・残りの枚数まで）。選んだら整えて入力欄の上に並べる。
    private func photoPicker(disabled: Bool) -> some View {
        let remaining = model.remainingImageSlots(room.id)
        return PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, remaining), selectionBehavior: .ordered,
                            matching: .images, photoLibrary: .shared()) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DeckTheme.secondary)
                .frame(width: 32, height: 34)
        }
        .disabled(disabled || remaining == 0)
        .opacity(disabled || remaining == 0 ? 0.4 : 1)
        .padding(.bottom, 3)
        .accessibilityLabel("写真を添える")
        .accessibilityIdentifier("attachPhoto")
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            model.attachImages(items, to: room.id) { item in try? await item.loadTransferable(type: Data.self) }
        }
    }

    /// 送れない理由（mac が教えるもの・接続・終了）。
    private var disabledReason: String? {
        if !model.connection.isConnected { return "Mac につながっていません" }
        if let reason = room.send.disabledReason, !reason.isEmpty { return reason }
        if room.send.mode == .unknown { return "このルームには送れません" }
        return nil
    }
}

/// 入力欄の上に並べる、送る前の画像（× で外す）。
private struct ImageStrip: View {
    let images: [ComposerImage]
    let preparing: Int
    let remove: (ComposerImage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    Image(uiImage: image.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeckTheme.border, lineWidth: 1))
                        .overlay(alignment: .topTrailing) {
                            Button { remove(image) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(DeckTheme.text, DeckTheme.background.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("この画像を外す")
                            .accessibilityIdentifier("removeImage")
                        }
                }
                ForEach(0..<preparing, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DeckTheme.inputSurface)
                        .frame(width: 58, height: 58)
                        .overlay(ProgressView().tint(DeckTheme.secondary))
                        .accessibilityLabel("写真を読み込み中")
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 6)
        }
    }
}
