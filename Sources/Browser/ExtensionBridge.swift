import AppKit
import WebKit

@available(macOS 15.4, *)
extension BrowserWindow:WKWebExtensionWindow {
    var extensions:ExtensionRuntime? { privateBrowsing ? nil : store.extensions(dataStore:websiteDataStore) }
    var extensionWindowVisible:Bool { !privateBrowsing && tabs.indices.contains(activeIndex) && tabs[activeIndex].extensionVisible }
    // WebKit requires a window's tab list to include its active tab. Hide the window while its active page is protected.
    func tabs(for context:WKWebExtensionContext)->[any WKWebExtensionTab] { extensionWindowVisible ? tabs.filter(\.extensionVisible) : [] }
    func activeTab(for context:WKWebExtensionContext)->(any WKWebExtensionTab)? { tabs.indices.contains(activeIndex) && !privateBrowsing && tabs[activeIndex].extensionVisible ? tabs[activeIndex] : nil }
    func isPrivate(for context:WKWebExtensionContext)->Bool { privateBrowsing }
    func focus(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) { window?.makeKeyAndOrderFront(nil); completionHandler(nil) }
}

@available(macOS 15.4, *)
extension BrowserTab:WKWebExtensionTab {
    var extensionVisible:Bool { owner?.privateBrowsing == false && ["http","https"].contains((webView?.url ?? url)?.scheme ?? "") }
    func window(for context:WKWebExtensionContext)->(any WKWebExtensionWindow)? { extensionVisible ? owner : nil }
    func indexInWindow(for context:WKWebExtensionContext)->Int { owner?.tabs.filter(\.extensionVisible).firstIndex(where:{$0 === self}) ?? 0 }
    func webView(for context:WKWebExtensionContext)->WKWebView? { extensionVisible ? webView : nil }
    func url(for context:WKWebExtensionContext)->URL? { guard extensionVisible,let url = webView?.url ?? url,context.hasAccess(to:url) else { return nil }; return url }
    func title(for context:WKWebExtensionContext)->String? { url(for:context) != nil ? title : nil }
    func isLoadingComplete(for context:WKWebExtensionContext)->Bool { webView?.isLoading == false }
    func isSelected(for context:WKWebExtensionContext)->Bool {
        guard let owner,owner.tabs.indices.contains(owner.activeIndex) else { return false }
        return owner.tabs[owner.activeIndex] === self
    }
    func shouldGrantPermissionsOnUserGesture(for context:WKWebExtensionContext)->Bool { false }
    func shouldBypassPermissions(for context:WKWebExtensionContext)->Bool { false }
    func activate(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let owner,!owner.capturing,extensionVisible,let index = owner.tabs.firstIndex(where:{$0 === self}) else { completionHandler(ExtensionPackage.Failure(message:"标签页当前不可操作")); return }
        owner.activate(index); completionHandler(nil)
    }
    func loadURL(_ url:URL,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let owner,!owner.capturing,extensionVisible,ExtensionRuntime.sitePattern(url) != nil else { completionHandler(ExtensionPackage.Failure(message:"扩展不能打开此地址")); return }
        self.url = url
        if let webView { webView.load(URLRequest(url:url)) }
        owner.renderTabs(); owner.saveSession(); completionHandler(nil)
    }
    func reload(fromOrigin:Bool,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard owner?.capturing == false,extensionVisible else { completionHandler(ExtensionPackage.Failure(message:"标签页当前不可操作")); return }
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }; completionHandler(nil)
    }
    func close(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let owner,!owner.capturing,extensionVisible,let index = owner.tabs.firstIndex(where:{$0 === self}) else { completionHandler(ExtensionPackage.Failure(message:"标签页当前不可操作")); return }
        owner.close(at:index); completionHandler(nil)
    }
}
