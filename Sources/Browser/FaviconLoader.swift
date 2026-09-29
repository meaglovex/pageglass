import AppKit
import ImageIO
import WebKit

@MainActor
final class FaviconLoader {
    private let cache = NSCache<NSString,NSImage>()
    private var pending:[URL:Task<NSImage?,Never>] = [:]
    private var failed = Set<URL>()
    init() { cache.countLimit = 128 }
    static func origin(_ url:URL)->URL? {
        guard ["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil else { return nil }
        var parts = URLComponents(url:url,resolvingAgainstBaseURL:false)
        parts?.path = "/";parts?.query = nil;parts?.fragment = nil;parts?.user = nil;parts?.password = nil
        return parts?.url
    }
    func cached(for page:URL)->NSImage? { Self.origin(page).flatMap { cache.object(forKey:$0.absoluteString as NSString) } }
    func image(for page:URL,candidates:[URL] = []) async -> NSImage? {
        guard let origin = Self.origin(page) else { return nil }
        if candidates.isEmpty,let found = cached(for:page) { return found }
        var seen = Set<URL>()
        let urls = (Array(candidates.prefix(3)) + [origin.appendingPathComponent("favicon.ico")]).filter {
            ["http","https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && $0.user == nil && $0.password == nil && seen.insert($0).inserted
        }
        for url in urls {
            if failed.contains(url) { continue }
            let task:Task<NSImage?,Never>
            if let existing = pending[url] { task = existing }
            else {
                task = Task {
                    guard let data = await IconDownload.fetch(url),let source = CGImageSourceCreateWithData(data as CFData,nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:32,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
                    let scale = 16.0/Double(max(cg.width,cg.height))
                    return NSImage(cgImage:cg,size:NSSize(width:Double(cg.width)*scale,height:Double(cg.height)*scale))
                }
                pending[url] = task
            }
            let image = await task.value;pending[url] = nil
            if let image { cache.setObject(image,forKey:origin.absoluteString as NSString);return image }
            if failed.count >= 128 { failed.removeAll() };failed.insert(url)
        }
        return cached(for:page)
    }
}

/// Bounded public icon requests; no browser cookies, credential store, or disk cache.
private final class IconDownload:NSObject,URLSessionDataDelegate {
    private var data = Data()
    private var session:URLSession?
    private let completion:CheckedContinuation<Data?,Never>
    private static let limit = 256*1024
    private init(_ completion:CheckedContinuation<Data?,Never>) { self.completion = completion }
    static func fetch(_ url:URL) async -> Data? {
        await withCheckedContinuation { continuation in
            let delegate = IconDownload(continuation)
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil;config.urlCredentialStorage = nil;config.urlCache = nil;config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 5;config.timeoutIntervalForResource = 8
            delegate.session = URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
            delegate.session?.dataTask(with:url).resume()
        }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode),response.expectedContentLength <= Int64(Self.limit) else { completionHandler(.cancel);return }
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive incoming:Data) {
        guard data.count+incoming.count <= Self.limit else { dataTask.cancel();return };data.append(incoming)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        guard let url = request.url,["http","https"].contains(url.scheme?.lowercased() ?? ""),url.user == nil,url.password == nil else { completionHandler(nil);return }
        completionHandler(request)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        completion.resume(returning:error == nil && !data.isEmpty ? data : nil)
        session.finishTasksAndInvalidate();self.session = nil
    }
}

extension BrowserWindow {
    func loadFavicon(for view:WKWebView) {
        guard let tab = tabs.first(where:{$0.webView === view}),let page = view.url,FaviconLoader.origin(page) != nil else { return }
        tab.iconTask?.cancel()
        tab.iconTask = Task { @MainActor [weak self,weak tab,weak view] in
            guard let self,let tab,let view else { return }
            let raw = try? await captureService.js(view,"Array.from(document.querySelectorAll('link[rel]')).filter(l=>l.rel.toLowerCase().split(/\\s+/).includes('icon')).slice(0,3).map(l=>l.href)") as? [String]
            let icon = await favicons.image(for:page,candidates:(raw ?? []).compactMap(URL.init(string:)))
            guard !Task.isCancelled,view.url == page,tab.webView === view else { return }
            tab.favicon = icon;renderTabs();renderBookmarks()
        }
    }
}
