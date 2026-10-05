import DeckCore
import SwiftUI

@main
struct ClaudeDeckApp: App {
    @State private var model = AppModel.launch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .tint(DeckTheme.accent)
                // 他のアプリから開かれたペアリングのリンクは、確認画面を出すだけで勝手には使わない。
                .onOpenURL { url in model.offerLink(url.absoluteString, source: .openedURL) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.connect()
            case .background: model.pause()
            default: break
            }
        }
    }
}

extension AppModel {
    static func launch() -> AppModel {
        #if DEBUG
        if let demo = DemoData.model(from: ProcessInfo.processInfo.arguments) { return demo }
        #endif
        return AppModel()
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.pairing == nil {
                PairingView(model: model)
            } else {
                RoomListScreen(model: model)
            }
        }
        .background(DeckTheme.background.ignoresSafeArea())
        .environment(model)
        .sheet(item: $model.pendingOffer) { offer in
            PairingConfirmView(model: model, offer: offer)
        }
    }
}
