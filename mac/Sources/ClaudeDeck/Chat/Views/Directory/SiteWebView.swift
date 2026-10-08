import AppKit
import MonitorKit
import SwiftUI
import WebKit

/// プレビューの今の様子（開いているページ・読み込み中・失敗）。ブラウザで開く時は今のページを渡す。
@MainActor
@Observable
final class SitePreviewState {
    var currentURL: URL?
    var loading = false
    var failure: String?

    /// ブラウザで開く先（今のページ、無ければ `fallback`）。
    func browserURL(fallback: URL?) -> URL? {
        SiteNavigationPolicy.browserURL(currentURL) ?? fallback
    }
}

/// サイトのプレビュー。`zoom` で縮めて表示幅（CSS ピクセル）ぶんを枠に収める。
struct SiteWebView: NSViewRepresentable {
    let url: URL
    /// 開発サーバーの時はその origin。ページの遷移をそこに限り、他はブラウザで開く。
    let origin: URL?
    let zoom: Double
    /// 変わったら読み直す。
    let reloadToken: Int
    let state: SitePreviewState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 見るだけなので、Cookie 等は手元に残さない。
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.origin = origin
        if view.pageZoom != zoom { view.pageZoom = zoom }
        guard coordinator.loadedURL != url || coordinator.loadedToken != reloadToken else { return }
        let sameURL = coordinator.loadedURL == url
        coordinator.loadedURL = url
        coordinator.loadedToken = reloadToken
        state.failure = nil
        if sameURL, view.url != nil {
            view.reloadFromOrigin()
        } else {
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: SitePreviewState
        var loadedURL: URL?
        var loadedToken = 0
        var origin: URL?

        init(state: SitePreviewState) {
            self.state = state
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            apply(SiteNavigationPolicy.decide(action.request.url, mainFrame: action.targetFrame?.isMainFrame ?? true, origin: origin))
        }

        /// 新しいウィンドウで開くリンクは同じ枠で開く（開発サーバーの外へのものはブラウザで）。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, apply(SiteNavigationPolicy.decide(url, mainFrame: true, origin: origin)) == .allow {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func apply(_ decision: SiteNavigationPolicy.Decision) -> WKNavigationActionPolicy {
            switch decision {
            case .allow: return .allow
            case .cancel: return .cancel
            case .openInBrowser(let url):
                NSWorkspace.shared.open(url)
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.loading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.loading = false
            state.currentURL = webView.url
            state.failure = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(error)
        }

        private func finish(_ error: Error) {
            state.loading = false
            // 取り消し（読み直しで前の読み込みを止めた時）は失敗として出さない。
            if (error as NSError).code == NSURLErrorCancelled { return }
            state.failure = "読み込めませんでした: \(error.localizedDescription)"
        }
    }
}
