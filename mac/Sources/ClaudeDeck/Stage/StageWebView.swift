import AppKit
import SwiftUI
import WebKit

/// monitor の埋め込み表示（`/?embed=stage`）を出す WKWebView。URL ごとに数枚を保持して切り替える。
struct StageWebView: NSViewRepresentable {
    let url: URL
    /// 変わったら保持中の表示を捨てて読み直す（monitor の再起動で SSE が切れた表示を残さないため）。
    let epoch: Int

    func makeNSView(context: Context) -> StageWebContainer {
        StageWebContainer()
    }

    func updateNSView(_ view: StageWebContainer, context: Context) {
        view.show(url, epoch: epoch)
    }

    static func dismantleNSView(_ view: StageWebContainer, coordinator: ()) {
        view.discardAll()
    }
}

final class StageWebContainer: NSView, WKNavigationDelegate {
    /// 行き来したルームへ戻った時に読み直しのちらつきを出さないよう、直近の数枚を生かしておく。
    private static let keepCount = 3

    private var cache: [URL: WKWebView] = [:]
    private var recent: [URL] = []
    private var currentURL: URL?
    private var epoch: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ url: URL, epoch: Int) {
        if self.epoch != epoch {
            discardAll()
            self.epoch = epoch
        }
        guard url != currentURL else { return }
        let web = cache[url] ?? makeWebView(url)
        cache[url] = web
        recent.removeAll { $0 == url }
        recent.append(url)
        if let old = currentURL, let oldView = cache[old] { oldView.removeFromSuperview() }
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        addSubview(web)
        currentURL = url
        evict()
    }

    func discardAll() {
        for web in cache.values {
            web.stopLoading()
            web.navigationDelegate = nil
            web.removeFromSuperview()
        }
        cache = [:]
        recent = []
        currentURL = nil
    }

    private func evict() {
        while recent.count > Self.keepCount {
            let url = recent.removeFirst()
            guard url != currentURL, let web = cache.removeValue(forKey: url) else { continue }
            web.stopLoading()
            web.navigationDelegate = nil
            web.removeFromSuperview()
        }
    }

    private func makeWebView(_ url: URL) -> WKWebView {
        let web = WKWebView(frame: bounds, configuration: WKWebViewConfiguration())
        // ページの地を透かしてパネルの地色を見せる。
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor(hex: StageTheme.panelHex)
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.setAccessibilityIdentifier("stage-webview")
        web.load(URLRequest(url: url))
        return web
    }

    // MARK: - WKNavigationDelegate

    /// 埋め込み表示の外（リンク等）へは移らない。
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let target = action.request.url
        let origin = cache.first { $0.value === webView }?.key
        let sameOrigin = target?.host == origin?.host && target?.port == origin?.port
        decisionHandler(sameOrigin || target?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryLater(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryLater(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        retryLater(webView)
    }

    /// monitor の起動直後で読めなかった時に、空のまま残さない。
    private func retryLater(_ webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak webView] in
            guard let self, let webView, let url = self.cache.first(where: { $0.value === webView })?.key else { return }
            webView.load(URLRequest(url: url))
        }
    }
}

/// ウィンドウの幅を知らせる（狭い時にパネルを自動で畳むため）。
struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat?

    func makeNSView(context: Context) -> WidthReportingView {
        let view = WidthReportingView()
        view.onChange = { width = $0 }
        return view
    }

    func updateNSView(_ view: WidthReportingView, context: Context) {
        view.onChange = { width = $0 }
    }
}

final class WidthReportingView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    private func report() {
        guard let width = window?.frame.width else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(width) }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
