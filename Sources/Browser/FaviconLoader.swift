import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Small on-disk icon store for normal windows, so a launch does not re-request every bookmarked site.
/// Holds only already-downsampled PNGs named by a hash of the origin. Private windows read it but never write;
/// any window may clear it, because history is shared and can be cleared from a private window.
struct FaviconDiskCache {
    let directory:URL
    let writable:Bool
    static let limit = 512, maxBytes = 64*1024
    private func file(_ origin:URL)->URL {
        directory.appendingPathComponent(SHA256.hash(data:Data(origin.absoluteString.utf8)).prefix(16).map { String(format:"%02x",$0) }.joined()+".png")
    }
    func image(for origin:URL)->CGImage? {
        let url = file(origin)
        guard let values = try? url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),values.isRegularFile == true,(values.fileSize ?? .max) <= Self.maxBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil),max(image.width,image.height) <= 64 else { return nil }
        return image
    }
    func store(_ image:CGImage,for origin:URL) {
        guard writable,max(image.width,image.height) <= 64 else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { return }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination),data.length <= Self.maxBytes,
              (try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])) != nil,
              (try? (data as Data).write(to:file(origin),options:.atomic)) != nil else { return }
        let keys:[URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:keys),files.count > Self.limit else { return }
        let date = { (url:URL) in (try? url.resourceValues(forKeys:Set(keys)).contentModificationDate) ?? .distantPast }
        for old in files.sorted(by:{ date($0) < date($1) }).prefix(files.count-Self.limit) { try? FileManager.default.removeItem(at:old) }
    }
    func clear() { try? FileManager.default.removeItem(at:directory) }
}

@MainActor
final class FaviconLoader {
    // These are already downsampled to 32 px. Keep a strict, small working set so
    // a recently loaded page's declared icon cannot disappear before bookmarks reuse it.
    private var cache:[URL:NSImage] = [:]
    private var recent:[URL] = []
    private let download:(URL) async -> Data?
    private var pending:[URL:Task<NSImage?,Never>] = [:]
    private var failed = Set<URL>()
    private let disk:FaviconDiskCache?
    init(download:@escaping (URL) async -> Data? = IconDownload.fetch,disk:FaviconDiskCache? = nil) { self.download = download; self.disk = disk }
    static func origin(_ url:URL)->URL? {
        guard ["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil else { return nil }
        var parts = URLComponents(url:url,resolvingAgainstBaseURL:false)
        parts?.path = "/";parts?.query = nil;parts?.fragment = nil;parts?.user = nil;parts?.password = nil
        return parts?.url
    }
    func cached(for page:URL)->NSImage? {
        guard let origin = Self.origin(page) else { return nil }
        if let image = cache[origin] { touch(origin);return image }
        guard let stored = disk?.image(for:origin) else { return nil }
        let image = Self.icon(stored);remember(image,for:origin,persist:false);return image
    }
    func clearDisk() { disk?.clear() }
    private static func icon(_ cg:CGImage)->NSImage {
        let scale = 16.0/Double(max(cg.width,cg.height))
        return NSImage(cgImage:cg,size:NSSize(width:Double(cg.width)*scale,height:Double(cg.height)*scale))
    }
    private func touch(_ origin:URL) { recent.removeAll { $0 == origin };recent.append(origin) }
    private func remember(_ image:NSImage,for origin:URL,persist:Bool = true) {
        cache[origin] = image;touch(origin)
        if persist,let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) { disk?.store(cg,for:origin) }
        if recent.count > 128 { cache.removeValue(forKey:recent.removeFirst()) }
    }
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
                task = Task { [download] in
                    guard let data = await download(url),let source = CGImageSourceCreateWithData(data as CFData,nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:32,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
                    return Self.icon(cg)
                }
                pending[url] = task
            }
            let image = await task.value;pending[url] = nil
            if let image { remember(image,for:origin);return image }
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
            tab.favicon = icon;updateTabAppearance(tab)
            if let icon,let origin = FaviconLoader.origin(page) {
                for sibling in tabs where sibling !== tab && sibling.favicon == nil {
                    guard let url = sibling.webView?.url ?? sibling.url,FaviconLoader.origin(url) == origin else { continue }
                    sibling.favicon = icon;updateTabAppearance(sibling)
                }
            }
            renderBookmarks(force:true)
        }
    }
}
