import UIKit

/// 文言に出す端末の呼び名（同じアプリが iPhone と iPad で動く）。
@MainActor
enum DeviceKind {
    static var name: String { name(for: UIDevice.current.userInterfaceIdiom) }

    static func name(for idiom: UIUserInterfaceIdiom) -> String {
        idiom == .pad ? "iPad" : "iPhone"
    }
}
