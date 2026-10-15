import AppKit
import WebKit

extension BrowserWindow {
    @objc func goHome() {
        if let url = Navigation.url(for:store.state.settings.homepage,searchEngine:store.state.settings.searchEngine) { load(url) } else { loadHome() }
    }
    @objc func toggleBookmark() {
        guard let url = webView.url,["http","https","file"].contains(url.scheme ?? "") else { return }
        let title = webView.title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        store.toggleBookmark(title:title.isEmpty ? (url.host ?? url.absoluteString) : title,url:url.absoluteString)
        status.stringValue = store.bookmark(for:url.absoluteString) == nil ? "已移除书签" : "已添加书签（⌘⇧B 显示书签栏）"
    }
    @objc func toggleBookmarksBar() { var settings = store.state.settings; settings.showBookmarksBar.toggle(); store.updateSettings(settings) }
    @objc func showBookmarks() { showLibrary(.bookmarks) }
    @objc func showHistory() { showLibrary(.history) }
    @objc func showDownloads() { showLibrary(.downloads) }
    func showLibrary(_ mode:LibraryController.Mode) {
        if libraryController == nil { libraryController = LibraryController(browser:self) }
        libraryController?.show(mode)
    }
    @objc func showSettings() {
        if settingsController == nil { settingsController = SettingsController(browser:self) }
        settingsController?.reloadValues(); settingsController?.showWindow(nil); settingsController?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func reopenTab() {
        guard !capturing,let saved = closedTabs.popLast() else { return }
        let tab = BrowserTab(url:saved.url.flatMap(URL.init(string:))); tab.title = saved.title
        tabs.append(tab); activate(tabs.count-1)
    }
    @objc func nextTab() { activate((activeIndex+1)%tabs.count) }
    @objc func previousTab() { activate((activeIndex+tabs.count-1)%tabs.count) }
    @objc func numberedTab(_ item:NSMenuItem) { activate(item.tag == 9 ? tabs.count-1 : min(item.tag-1,tabs.count-1)) }
    func moveTab(_ source:UUID,relativeTo target:UUID,after:Bool = false) {
        guard !capturing,source != target,let from = tabs.firstIndex(where:{$0.id == source}),let to = tabs.firstIndex(where:{$0.id == target}) else { return }
        let active = tabs[activeIndex].id, tab = tabs.remove(at:from)
        let oldVisibleIndex:Int?
        if #available(macOS 15.4,*) { oldVisibleIndex = (Array(tabs.prefix(from))+[tab]).filter(\.extensionVisible).firstIndex(where:{$0 === tab}) } else { oldVisibleIndex = nil }
        tabs.insert(tab,at:min(to + (after ? 1 : 0) - (from < to ? 1 : 0),tabs.count)); activeIndex = tabs.firstIndex(where:{$0.id == active}) ?? 0
        if #available(macOS 15.4,*),extensionWindowVisible,let oldVisibleIndex { extensions?.controller.didMoveTab(tab,from:oldVisibleIndex,in:self) }
        renderTabs(revealActive:true); saveSession()
    }
    func tabMenu(_ id:UUID)->NSMenu {
        let menu = NSMenu()
        guard tabs.contains(where:{$0.id == id}) else { return menu }
        for (title,command) in [("重新加载","reload"),("复制标签页","duplicate"),("关闭标签页","close"),("关闭其他标签页","others"),("关闭右侧标签页","right")] {
            let item = NSMenuItem(title:title,action:#selector(tabCommand(_:)),keyEquivalent:""); item.target = self; item.representedObject = [id.uuidString,command]; menu.addItem(item)
        }
        menu.addItem(.separator()); let reopen = NSMenuItem(title:"重新打开关闭的标签页",action:#selector(reopenTab),keyEquivalent:""); reopen.target = self; reopen.isEnabled = !closedTabs.isEmpty; menu.addItem(reopen)
        return menu
    }
    @objc func tabCommand(_ item:NSMenuItem) {
        guard !capturing,let data = item.representedObject as? [String],let index = tabs.firstIndex(where:{$0.id.uuidString == data[0]}) else { return }
        let tab = tabs[index]
        switch data[1] {
        case "reload": tab.webView?.reload()
        case "duplicate": if let url = tab.webView?.url ?? tab.url { openTab(url) }
        case "close": close(at:index)
        case "others": for i in tabs.indices.reversed() where i != index { close(at:i) }
        case "right": for i in tabs.indices.reversed() where i > index { close(at:i) }
        default: break
        }
    }
    @objc func siteInfo() {
        let alert = NSAlert(); alert.messageText = webView.url?.host ?? "本地页面"
        let secure = webView.url?.scheme == "https" && webView.hasOnlySecureContent
        alert.informativeText = secure ? "当前页面通过 HTTPS 连接，证书由系统 WebKit 校验。\n网站摄像头和麦克风权限会单独询问。" : "当前页面不是完整的 HTTPS 安全上下文。\n请谨慎输入密码或其他敏感信息。"
        alert.addButton(withTitle:"关闭"); alert.runModal()
    }
    @objc func showMore(_ sender:NSButton) {
        let menu = makeBrowserMenu()
        menu.popUp(positioning:nil,at:NSPoint(x:sender.bounds.minX,y:sender.bounds.minY),in:sender)
    }

    @objc func savePage() {
        guard !capturing else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension:"webarchive")!]; panel.nameFieldStringValue = (webView.title ?? "网页") + ".webarchive"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        webView.createWebArchiveData { [weak self] result in
            do { try result.get().write(to:url,options:.atomic); self?.status.stringValue = "网页已保存" }
            catch { self?.status.stringValue = "保存失败：\(error.localizedDescription)" }
        }
    }
    @objc func printPage() {
        let operation = webView.printOperation(with:NSPrintInfo.shared)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
    }
    func cancelDownload(id:UUID) {
        guard let pair = downloadRecords.first(where:{$0.value.id == id}),let download = downloads[pair.key] else {
            if let owner = (NSApp.delegate as? AppDelegate)?.windows.first(where: { $0 !== self && $0.downloadRecords.values.contains(where:{$0.id == id}) }) { owner.cancelDownload(id:id) }
            return
        }
        download.cancel { [weak self] _ in self?.updateDownload(download,state:"已取消"); self?.downloads.removeValue(forKey:pair.key); self?.downloadObservers.removeValue(forKey:pair.key) }
    }
    /// fractionCompleted changes for every received chunk. Only a new whole percent touches records, the store and windows.
    func updateDownloadProgress(_ download:WKDownload,percent:Int) {
        let state = "下载中 \(percent)%"
        guard downloadRecords[ObjectIdentifier(download)]?.state != state else { return }
        updateDownload(download,state:state)
    }
    func updateDownload(_ download:WKDownload,state:String,path:String? = nil) {
        let key = ObjectIdentifier(download)
        guard var record = downloadRecords[key] else { return }
        record.state = state; if let path { record.path = path }; downloadRecords[key] = record
        if !privateBrowsing && !isTesting { store.saveDownload(record) }
        libraryController?.refresh(); syncDownloadIndicator()
    }
}
