import AppKit
import WebKit

@MainActor
final class BrowserTab: NSObject {
    let id = UUID()
    weak var owner:BrowserWindow?
    let container = NSView()
    var webView: WKWebView?
    var url: URL?
    var pendingURL: URL?
    var failure: PageFailure?
    var title = "新标签页"
    var favicon:NSImage?
    var iconTask:Task<Void,Never>?
    let recording = InteractionRecording()
    var observations: [NSKeyValueObservation] = []

    init(url: URL? = nil) { self.url = url }

    func release() {
        iconTask?.cancel();iconTask = nil
        recording.reset()
        url = webView?.url ?? url
        if let webView { DeveloperTools.close(webView) }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pageglass", contentWorld: CaptureService.world)
        observations.removeAll()
        webView?.removeFromSuperview()
        container.removeFromSuperview()
        webView = nil
    }
}
