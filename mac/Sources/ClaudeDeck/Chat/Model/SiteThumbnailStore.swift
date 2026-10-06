import AppKit
import MonitorKit
import WebKit

/// 「ディレクトリ」の行の LP のサムネイル。撮り直すのは書き出しが変わった時だけ・1 つずつ（WKWebView を何枚も立てると重いため）。
@MainActor
@Observable
final class SiteThumbnailStore {
    static let shared = SiteThumbnailStore()

    /// プロジェクトのパス → サムネイル。
    private(set) var images: [String: NSImage] = [:]

    private struct Job {
        let key: String
        let exportDir: String
        let file: URL
    }

    /// 同じ行を描き直すたびにファイルを見に行かないための間隔。
    private static let recheckInterval: TimeInterval = 30
    @ObservationIgnored private var checked: [String: (signature: String, at: Date)] = [:]
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private let capturer = SiteSnapshotter()

    /// 必要なら読み込む・撮る。設定の `site` が変わった時はすぐ見直す。
    func request(_ project: ManagedProject) {
        let key = project.path
        let signature = project.site?.path ?? ""
        if let last = checked[key], last.signature == signature, Date().timeIntervalSince(last.at) < Self.recheckInterval { return }
        checked[key] = (signature, Date())
        Task {
            let found = await Task.detached(priority: .utility) { () -> (String, URL, Bool)? in
                guard let location = SiteLocator.lookup(project: project).location,
                      let modified = SiteLocator.exportModified(location) else { return nil }
                let file = SiteThumbnails.directory.appendingPathComponent(
                    SiteThumbnails.fileName(exportDir: location.exportDir, modified: modified))
                return (location.exportDir, file, FileManager.default.fileExists(atPath: file.path))
            }.value
            guard let (exportDir, file, cached) = found else {
                images[key] = nil
                return
            }
            if cached, let image = NSImage(contentsOf: file) {
                images[key] = image
                return
            }
            enqueue(Job(key: key, exportDir: exportDir, file: file))
        }
    }

    private func enqueue(_ job: Job) {
        guard !queue.contains(where: { $0.file == job.file }) else { return }
        queue.append(job)
        runNext()
    }

    private func runNext() {
        guard !capturing, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        capturing = true
        Task {
            defer {
                capturing = false
                runNext()
            }
            guard let base = try? await SitePreviewServers.shared.baseURL(for: job.exportDir),
                  let image = await capturer.capture(base) else { return }
            images[job.key] = image
            await Task.detached(priority: .utility) { Self.store(image, at: job.file, exportDir: job.exportDir) }.value
        }
    }

    /// PNG で書き、同じサイトの古いものを消す。
    nonisolated private static func store(_ image: NSImage, at file: URL, exportDir: String) {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        guard (try? png.write(to: file, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for stale in SiteThumbnails.stale(in: names, exportDir: exportDir, keep: file.lastPathComponent) {
            try? fm.removeItem(at: dir.appendingPathComponent(stale))
        }
    }
}

/// 画面に出さないウィンドウの中で WKWebView にページを開いて撮る（ウィンドウに載せないと描かれないため）。
@MainActor
private final class SiteSnapshotter: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var finished: CheckedContinuation<Bool, Never>?
    /// 読み込みの後、フォントや画像の差し込みを待つ時間。
    private static let settle: Duration = .milliseconds(800)
    private static let timeout: Duration = .seconds(15)

    func capture(_ url: URL) async -> NSImage? {
        let size = NSSize(width: SiteThumbnails.captureWidth, height: SiteThumbnails.captureHeight)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        self.webView = webView
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            window.orderOut(nil)
            window.contentView = nil
            self.window = nil
            self.webView = nil
        }

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            finished = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                self?.resume(false)
            }
        }
        guard loaded else { return nil }
        try? await Task.sleep(for: Self.settle)
        let config2 = WKSnapshotConfiguration()
        config2.snapshotWidth = NSNumber(value: SiteThumbnails.storedWidth)
        return try? await webView.takeSnapshot(configuration: config2)
    }

    private func resume(_ value: Bool) {
        finished?.resume(returning: value)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(false) }

    /// 撮るのは書き出しのトップだけなので、外へ出る遷移はしない。
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "about" || scheme == "blob" || (scheme == "data" && action.targetFrame?.isMainFrame == false) { return .allow }
        return url.host == "127.0.0.1" ? .allow : .cancel
    }
}
