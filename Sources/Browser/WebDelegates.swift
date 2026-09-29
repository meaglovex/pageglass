import AppKit
import WebKit

extension BrowserWindow: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if capturing && action.targetFrame?.isMainFrame == true { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), ["http","https"].contains(url.scheme ?? "") {
            decisionHandler(.cancel); openTab(url,inBackground:!action.modifierFlags.contains(.shift)); return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http","https","file","about","blob","data"].contains(scheme) {
            if action.targetFrame?.isMainFrame == true { tabs.first(where:{$0.webView === webView})?.pendingURL = url }
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false {
                let alert = NSAlert(); alert.messageText = "在外部应用中打开链接？"; alert.informativeText = "协议：\(scheme)"; alert.addButton(withTitle:"打开"); alert.addButton(withTitle:"取消")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        }
    }
    func webView(_ webView:WKWebView,decidePolicyFor response:WKNavigationResponse,decisionHandler:@escaping(WKNavigationResponsePolicy)->Void) { decisionHandler(response.canShowMIMEType ? .allow : .download) }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) {
        tabs.first(where:{$0.webView === webView})?.failure = nil
        tabs.first(where:{$0.webView === webView})?.iconTask?.cancel()
        // A failed or cancelled navigation can leave the old document alive.
        webView.evaluateJavaScript("globalThis.__pageglass?.stop();globalThis.__pageglassRecorder?.stop(false)",in:nil,in:CaptureService.world)
        tabs.first(where:{$0.webView === webView})?.recording.reset()
        if webView === self.activeWebView { selecting = false; status.stringValue = "正在加载…"; syncChrome() }
    }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!) {
        if let tab = tabs.first(where:{$0.webView === webView}) { tab.favicon = nil; updateTabAppearance(tab) }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        if let tab = tabs.first(where:{$0.webView === webView}) { tab.failure = nil; tab.pendingURL = webView.url }
        loadFavicon(for:webView)
        if webView.url == Resources.bundle.url(forResource:"home",withExtension:"html",subdirectory:"Resources") {
            let destination = Navigation.url(for:"test",searchEngine:store.state.settings.searchEngine)!
            var endpoint = URLComponents(url:destination,resolvingAgainstBaseURL:false)!; let queryName = endpoint.queryItems?.first?.name ?? "q"; endpoint.query = nil
            webView.callAsyncJavaScript("document.querySelector('#search').action=endpoint;document.querySelector('#search input').name=queryName;document.querySelector('#private').style.display=isPrivate?'block':'none';",arguments:["endpoint":endpoint.string!,"queryName":queryName,"isPrivate":privateBrowsing],in:nil,in:CaptureService.world) { _ in }
        }
        if !privateBrowsing, !isTesting, let url = webView.url { store.visit(title:webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? "网页",url:url.absoluteString) }
        if webView === self.activeWebView { status.stringValue = "就绪 · \(webView.url?.scheme == "https" ? "HTTPS" : "本地 / HTTP") · ⌘⇧C 捕获元素"; syncChrome(); saveSession() }
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { report(error,view:webView) }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { report(error,view:webView) }
    private func report(_ error:Error,view:WKWebView) {
        let error = error as NSError
        // Policy handoff (102) and media-document handoff (204) are not page failures.
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled),
              !(error.domain == "WebKitErrorDomain" && [102,204].contains(error.code)),
              let tab = tabs.first(where:{$0.webView === view}) else { return }
        let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab.pendingURL ?? view.url
        tab.failure = PageFailure(message:"无法打开 \(url?.host ?? "页面")：\(error.localizedDescription)",url:url)
        if view === activeWebView { syncChrome() }
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
        tabs.first(where:{$0.webView === webView})?.recording.reset()
        if let tab = tabs.first(where:{$0.webView === webView}) { tab.failure = PageFailure(message:"页面进程已退出，可以重新加载此标签页。",url:webView.url ?? tab.url) }
        if webView === self.activeWebView { syncChrome() }
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        guard !capturing, action.targetFrame == nil else { return nil }
        let tab = BrowserTab(); tabs.append(tab)
        let newView = createWebView(for:tab,configuration:configuration); activate(tabs.count-1)
        return newView
    }
    func webViewDidClose(_ webView:WKWebView) { if let index = tabs.firstIndex(where:{$0.webView === webView}) { close(at:index) } }
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = message; alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView:WKWebView,runJavaScriptTextInputPanelWithPrompt prompt:String,defaultText:String?,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(String?)->Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = prompt
        let field = NSTextField(frame:NSRect(x:0,y:0,width:300,height:26)); field.stringValue = defaultText ?? ""; alert.accessoryView = field
        alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消"); completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView:WKWebView,runOpenPanelWith parameters:WKOpenPanelParameters,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping([URL]?)->Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView:WKWebView,requestMediaCapturePermissionFor origin:WKSecurityOrigin,initiatedByFrame frame:WKFrameInfo,type:WKMediaCaptureType,decisionHandler:@escaping(WKPermissionDecision)->Void) { decisionHandler(.prompt) }
    func webView(_ webView:WKWebView,navigationAction:WKNavigationAction,didBecome download:WKDownload) { register(download) }
    func webView(_ webView:WKWebView,navigationResponse:WKNavigationResponse,didBecome download:WKDownload) { register(download) }
    private func register(_ download:WKDownload) {
        let key = ObjectIdentifier(download); downloads[key] = download; download.delegate = self
        downloadRecords[key] = DownloadRecord(name:download.originalRequest?.url?.lastPathComponent ?? "文件",source:download.originalRequest?.url?.absoluteString ?? "")
        updateDownload(download,state:"等待保存")
    }
    func download(_ download:WKDownload,decideDestinationUsing response:URLResponse,suggestedFilename:String,completionHandler:@escaping(URL?)->Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath:suggestedFilename).lastPathComponent
        if var record = downloadRecords[ObjectIdentifier(download)] { record.name = suggestedFilename; downloadRecords[ObjectIdentifier(download)] = record }
        if panel.runModal() == .OK,let url = panel.url {
            updateDownload(download,state:"下载中",path:url.path)
            downloadObservers[ObjectIdentifier(download)] = download.progress.observe(\.fractionCompleted,options:[.new]) { [weak self,weak download] progress,_ in
                DispatchQueue.main.async { guard let download,self?.downloads[ObjectIdentifier(download)] != nil else { return }; self?.updateDownload(download,state:"下载中 \(Int(progress.fractionCompleted*100))%") }
            }
            completionHandler(url)
        } else { updateDownload(download,state:"已取消"); completionHandler(nil) }
    }
    func downloadDidFinish(_ download:WKDownload) { updateDownload(download,state:"已完成"); downloads.removeValue(forKey:ObjectIdentifier(download)); downloadObservers.removeValue(forKey:ObjectIdentifier(download)); status.stringValue = "下载完成，可在下载管理中打开" }
    func download(_ download:WKDownload,didFailWithError error:Error,resumeData:Data?) { updateDownload(download,state:(error as NSError).code == NSURLErrorCancelled ? "已取消" : "失败：\(error.localizedDescription)"); downloads.removeValue(forKey:ObjectIdentifier(download)); downloadObservers.removeValue(forKey:ObjectIdentifier(download)); status.stringValue = "下载结束：\(error.localizedDescription)" }
}
