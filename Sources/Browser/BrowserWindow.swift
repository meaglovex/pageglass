import AppKit
import WebKit

final class BrowserWindow: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    let id = UUID()
    let privateBrowsing: Bool
    let store: BrowserStore
    let websiteDataStore: WKWebsiteDataStore
    var tabs: [BrowserTab] = []
    var activeIndex = 0
    var closedTabs: [SavedTab] = []
    let content = NSView()
    let tabRow = NSStackView()
    let tabScroll = NSScrollView()
    var tabButtons: [UUID:TabButton] = [:]
    var tabWidths: [UUID:NSLayoutConstraint] = [:]
    var tabPopover: NSPopover?
    var commandPalette:CommandPaletteController?
    var extensionManager:NSWindowController?
    var bookmarkPopover: NSPopover?
    var overflowBookmarks: [PageRecord] = []
    var renderedBookmarks: [PageRecord]?
    var renderedBookmarkWidth: CGFloat = 0
    var renderedBookmarksVisible = false
    var toolbarTools:[ToolbarTool:NSView] = [:]
    var tabScrollWidth:NSLayoutConstraint?
    let captureMenuButton = ChromeButton(), downloadButton = ChromeButton(), extensionButton = ChromeButton()
    let extensionActionBar = NSStackView()
    var extensionActionButtons:[UUID:ChromeButton] = [:]
    weak var omnibox:ChromeStackView?
    let errorBar = NSStackView(), errorLabel = NSTextField(labelWithString:"")
    let bookmarkRow = NSStackView()
    let address = NSTextField()
    let status = BrowserNotice(labelWithString: "")
    let back = ChromeButton(), forward = ChromeButton(), refresh = ChromeButton(), bookmarkButton = ChromeButton(), siteButton = ChromeButton()
    let pick = ChromeButton(), captureAll = ChromeButton(), recordInteraction = ChromeButton()
    let progress = NSProgressIndicator()
    let findBar = NSStackView(), findField = NSSearchField(), findResult = NSTextField(labelWithString:"")
    let captureService = CaptureService()
    let favicons = FaviconLoader()
    var latest: CaptureResult?
    var selecting = false
    var capturing = false
    var captureTask: Task<Void,Never>?
    var captureProgress = ""
    var selectionDescription = ""
    var recordingBarHidden = false
    let captureBar = ChromeStackView(), captureLabel = NSTextField(labelWithString:"")
    let cancelCaptureButton = NSButton(), parentCaptureButton = NSButton()
    var captureSidebar:CaptureSidebar?
    var captureIntro:CaptureIntroView?
    var captureLibraryController: CaptureLibraryController?
    var downloads: [ObjectIdentifier: WKDownload] = [:]
    var downloadRecords: [ObjectIdentifier:DownloadRecord] = [:]
    var downloadObservers: [ObjectIdentifier:NSKeyValueObservation] = [:]
    var libraryController: LibraryController?
    var settingsController: SettingsController?
    var storeObserver: NSObjectProtocol?
    var suggestionPanel: NSPanel?
    var suggestions: [PageRecord] = []
    var selectedSuggestion = -1
    var activeWebView: WKWebView? { tabs.indices.contains(activeIndex) ? tabs[activeIndex].webView : nil }
    var webView: WKWebView { activeWebView! }
    var isTesting: Bool { CommandLine.arguments.contains("--smoke") || BenchmarkMode.enabled }

    init(privateBrowsing:Bool = false,store:BrowserStore = .shared,session:SavedWindow? = nil,dataStore:WKWebsiteDataStore? = nil) {
        self.privateBrowsing = privateBrowsing; self.store = store
        websiteDataStore = dataStore ?? (privateBrowsing || CommandLine.arguments.contains("--smoke") ? .nonPersistent() : QAProfile.current.map { WKWebsiteDataStore(forIdentifier:$0.websiteDataID) } ?? .default())
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "Pageglass"
        window.minSize = NSSize(width:820,height:520)
        if let qa = QAProfile.current {
            if let width = qa.width { window.setContentSize(NSSize(width:width,height:860)) }
            if let appearance = qa.appearance { window.appearance = NSAppearance(named:appearance == "Aqua" ? .aqua : .darkAqua) }
        }
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = false
        super.init(window:window)
        window.delegate = self; window.center(); buildInterface(); applyAppearance()
        if let session, !privateBrowsing {
            tabs = session.tabs.map { saved in
                let tab = BrowserTab(url:saved.url.flatMap(URL.init(string:))); tab.title = saved.title; return tab
            }
        }
        if tabs.isEmpty { tabs = [BrowserTab()] }
        activate(max(0,min(session?.active ?? 0,tabs.count-1)))
        if #available(macOS 15.4,*),let extensions { extensions.opened(self) }
        storeObserver = NotificationCenter.default.addObserver(forName:BrowserStore.changed,object:store,queue:.main) { [weak self] _ in
            self?.applyAppearance(); self?.renderBookmarks(); self?.updateToolbarLayout(); self?.syncChrome()
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) } }

    func createWebView(for tab:BrowserTab,configuration:WKWebViewConfiguration? = nil)->WKWebView {
        tab.owner = self
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = websiteDataStore }
        if #available(macOS 15.4,*) { config.webExtensionController = privateBrowsing ? nil : extensions?.controller }
        config.preferences.isElementFullscreenEnabled = true
        DeveloperTools.enable(config.preferences)
        let controller = WKUserContentController(); config.userContentController = controller
        controller.add(WeakCaptureHandler(self),contentWorld:CaptureService.world,name:"pageglass")
        controller.addUserScript(WKUserScript(source:CaptureService.script,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:CaptureService.world))
        controller.addUserScript(WKUserScript(source:InteractionRecording.script,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:CaptureService.world))
        let view = WKWebView(frame:.zero,configuration:config)
        view.allowsBackForwardNavigationGestures = true; view.navigationDelegate = self; view.uiDelegate = self
        view.isInspectable = true; view.pageZoom = store.state.settings.defaultZoom
        tab.webView = view
        tab.observations = [
            view.observe(\.title,options:[.new]) { [weak self,weak tab] view,_ in
                DispatchQueue.main.async { if let tab { tab.title = self?.displayTitle(view) ?? "新标签页"; self?.updateTabAppearance(tab) }; self?.syncChrome()
                    if let self,!self.privateBrowsing,!self.isTesting,let url = view.url { self.store.updateHistoryTitle(url:url.absoluteString,title:view.title ?? "") }
                }
            },
            view.observe(\.url,options:[.new]) { [weak self,weak tab] view,_ in DispatchQueue.main.async { if let tab { tab.url = view.url; tab.title = self?.displayTitle(view) ?? tab.title; self?.updateTabAppearance(tab) }; self?.syncChrome() } },
            view.observe(\.estimatedProgress,options:[.new]) { [weak self] _,_ in DispatchQueue.main.async { self?.syncChrome() } },
            view.observe(\.isLoading,options:[.new]) { [weak self] _,_ in DispatchQueue.main.async { self?.syncChrome() } }
        ]
        return view
    }
    func activate(_ index:Int) {
        guard !capturing,tabs.indices.contains(index) else { return }
        bookmarkPopover?.close(); tabPopover?.close()
        dismissCaptureIntro()
        dismissSuggestions(); commandPalette?.dismiss(restoreFocus:false); hideCaptureSidebar()
        if tabs.indices.contains(activeIndex),let old = tabs[activeIndex].webView {
            if index != activeIndex { tabs[activeIndex].recording.pause(old) }
            old.evaluateJavaScript("globalThis.__pageglass?.stop()",in:nil,in:CaptureService.world); tabs[activeIndex].container.removeFromSuperview()
        }
        selecting = false; activeIndex = index
        let tab = tabs[index], fresh = tabs[index].webView == nil
        let view = tab.webView ?? createWebView(for:tab)
        // WebKit docks the inspector beside its WebView and resizes its frame.
        // A per-tab autoresizing container lets it own that split without Auto Layout restoring full size.
        tab.container.frame = content.bounds;tab.container.autoresizingMask = [.width,.height]
        content.addSubview(tab.container,positioned:.below,relativeTo:status)
        if view.superview !== tab.container {
            view.frame = tab.container.bounds;view.autoresizingMask = [.width,.height]
            tab.container.addSubview(view)
        }
        window?.makeFirstResponder(view)
        if fresh { if let url = tab.url { load(url) } else { loadHome() } }
        status.stringValue = ""
        renderTabs(revealActive:true); syncChrome(); saveSession()
    }
    func syncChrome() {
        if #available(macOS 15.4,*) { extensions?.sync(self) }
        guard tabs.indices.contains(activeIndex),let view = tabs[activeIndex].webView else { return }
        if window?.firstResponder !== address.currentEditor() { address.stringValue = displayURL(view.url) }
        back.isEnabled = view.canGoBack && !capturing; forward.isEnabled = view.canGoForward && !capturing
        progress.doubleValue = view.estimatedProgress; progress.isHidden = !view.isLoading
        pick.isEnabled = !capturing; captureAll.isEnabled = !capturing; captureMenuButton.isEnabled = !capturing; address.isEnabled = !capturing
        recordInteraction.isEnabled = !capturing && !selecting
        let recording = interactionRecording?.isRecording == true
        recordInteraction.image = NSImage(systemSymbolName:recording ? "stop.circle.fill" : "record.circle",accessibilityDescription:recording ? "停止交互记录" : "记录交互")
        recordInteraction.contentTintColor = recording ? .systemRed : .secondaryLabelColor
        let recordingLabel = recording ? "停止交互记录（已记录 \(max(0,(interactionRecording?.frames.count ?? 1)-1)) 次操作）" : "记录交互（⌘⇧I）"
        recordInteraction.toolTip = recordingLabel; recordInteraction.setAccessibilityLabel(recordingLabel)
        refresh.isEnabled = !capturing
        refresh.image = NSImage(systemSymbolName:view.isLoading ? "xmark" : "arrow.clockwise",accessibilityDescription:view.isLoading ? "停止加载" : "重新加载")
        pick.toolTip = selecting ? "取消捕获（Esc）" : "捕获元素（⌘⇧C）"
        pick.contentTintColor = selecting ? .systemBlue : .labelColor
        pick.title = selecting ? "选取中" : "捕获"
        pick.setAccessibilityLabel(selecting ? "取消选取（Esc）" : "捕获元素（⌘⇧C）")
        updateToolbarLayout()
        let marked = view.url.map { store.bookmark(for:$0.absoluteString) != nil } ?? false
        bookmarkButton.image = NSImage(systemSymbolName:marked ? "star.fill" : "star",accessibilityDescription:marked ? "移除书签" : "添加书签")
        bookmarkButton.contentTintColor = marked ? .systemBlue : .secondaryLabelColor
        siteButton.image = NSImage(systemSymbolName:view.url?.scheme == "https" ? "lock" : "info.circle",accessibilityDescription:"网站信息")
        window?.title = "\(displayTitle(view)) — Pageglass\(privateBrowsing ? "（无痕）" : "")"
        syncPageFailure()
        syncCaptureBar()
    }
    func displayTitle(_ view:WKWebView)->String {
        if let title = view.title?.trimmingCharacters(in:.whitespacesAndNewlines), !title.isEmpty { return title }
        guard let url = view.url, !displayURL(url).isEmpty, url.absoluteString != "about:blank" else { return "新标签页" }
        if !url.pathExtension.isEmpty { return url.lastPathComponent }
        return url.host ?? (url.isFileURL ? url.lastPathComponent : "网页")
    }
    func displayURL(_ url:URL?)->String {
        guard let url else { return "" }
        if url == Resources.bundle.url(forResource:"home",withExtension:"html",subdirectory:"Resources") { return "" }
        return url.absoluteString
    }
    func load(_ url:URL) {
        dismissCaptureIntro()
        dismissSuggestions()
        tabs[activeIndex].pendingURL = url
        tabs[activeIndex].failure = nil
        syncPageFailure()
        if url.isFileURL { webView.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url:url)) }
    }
    func loadHome() { load(Resources.bundle.url(forResource:"home",withExtension:"html",subdirectory:"Resources")!) }
    func savedWindow()->SavedWindow {
        SavedWindow(tabs:tabs.map { tab in
            let url = tab.webView?.url ?? tab.url
            return SavedTab(url:url.flatMap { ["http","https","file"].contains($0.scheme ?? "") && $0 != Resources.bundle.url(forResource:"home",withExtension:"html",subdirectory:"Resources") ? $0.absoluteString : nil },title:tab.title)
        },active:activeIndex)
    }
    func saveSession() {
        guard !isTesting,!privateBrowsing else { return }
        (NSApp.delegate as? AppDelegate)?.saveSessions()
    }
    func windowWillClose(_ notification:Notification) {
        captureTask?.cancel(); cancelCapture()
        dismissSuggestions(); commandPalette?.dismiss(restoreFocus:false); saveSession()
        libraryController?.close(); settingsController?.close(); extensionManager?.close(); tabPopover?.close(); bookmarkPopover?.close(); captureSidebar?.detail.closePreviews()
        captureLibraryController?.close()
        for download in downloads.values { updateDownload(download,state:"已取消：窗口已关闭"); download.cancel { _ in } }
        downloadObservers.removeAll(); downloads.removeAll()
        if #available(macOS 15.4,*) { extensions?.closed(self) }
        for tab in tabs { tab.release() }
        (NSApp.delegate as? AppDelegate)?.closed(self)
    }
    override func cancelOperation(_ sender:Any?) {
        if bookmarkPopover?.isShown == true { dismissBookmarkOverflow() }
        else if tabPopover?.isShown == true { dismissTabList() }
        else if captureSidebar?.isHidden == false { dismissCaptureSidebar() }
        else if captureIntro != nil { dismissCaptureIntro() }
        else if selecting || capturing { cancelCapture() }
        // NSResponder declares this text action, but NSWindowController does not
        // implement it. Calling super here raises an Objective-C exception.
        else if let view = activeWebView,view.isLoading { view.stopLoading() }
    }
    func windowDidUpdate(_ notification:Notification) {
        let editor = address.currentEditor()
        let focused = window?.isKeyWindow == true && editor != nil && window?.firstResponder === editor
        if omnibox?.showsFocus != focused { omnibox?.showsFocus = focused }
    }
    func windowDidBecomeKey(_ notification:Notification) { if #available(macOS 15.4,*) { extensions?.controller.didFocusWindow(extensionWindowVisible ? self : nil) }; offerCaptureIntroIfNeeded() }
    func windowDidResignKey(_ notification:Notification) {
        dismissSuggestions(); omnibox?.showsFocus = false
        if #available(macOS 15.4,*) { extensions?.controller.didFocusWindow(nil) }
    }
    func windowDidResize(_ notification:Notification) { renderTabs(revealActive:true); renderBookmarks(); updateToolbarLayout(); dismissSuggestions(); tabPopover?.close(); bookmarkPopover?.close() }
    @objc func newTab() { guard !capturing else { return }; tabs.append(BrowserTab()); activate(tabs.count-1); address.stringValue = ""; focusAddress() }
    func openTab(_ url:URL,inBackground:Bool = false) {
        guard !capturing else { return }
        tabs.append(BrowserTab(url:url))
        if inBackground { renderTabs(); saveSession() } else { activate(tabs.count-1) }
    }
    @objc func closeTab() { close(at:activeIndex) }
    func close(at index:Int) {
        guard !capturing,tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        closedTabs.append(SavedTab(url:(tab.webView?.url ?? tab.url)?.absoluteString,title:tab.title))
        if closedTabs.count > 30 { closedTabs.removeFirst() }
        if tabs.count == 1 { window?.close(); return }
        tab.release(); tabs.remove(at:index)
        if index < activeIndex { activeIndex -= 1 }
        activeIndex = min(activeIndex,tabs.count-1); activate(activeIndex)
    }
    @objc func navigate() {
        guard (address.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let input = selectedSuggestion >= 0 && suggestions.indices.contains(selectedSuggestion) ? suggestions[selectedSuggestion].url : address.stringValue
        guard !capturing,let url = Navigation.url(for:input,searchEngine:store.state.settings.searchEngine) else { status.stringValue = "请输入有效的网址或搜索词"; return }
        window?.makeFirstResponder(webView); load(url)
    }
    @objc func focusAddress() {
        tabPopover?.close(); bookmarkPopover?.close(); commandPalette?.dismiss(restoreFocus:false)
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(address); address.selectText(nil)
    }
    @objc func goBack() { if !capturing { webView.goBack() } }
    @objc func goForward() { if !capturing { webView.goForward() } }
    @objc func reload() { if !capturing { if webView.isLoading { webView.stopLoading() } else { webView.reload() } } }
    @objc func zoomIn() { if !capturing { webView.pageZoom = min(3,webView.pageZoom+0.1); status.stringValue = "缩放 \(Int(webView.pageZoom*100))%" } }
    @objc func zoomOut() { if !capturing { webView.pageZoom = max(0.5,webView.pageZoom-0.1); status.stringValue = "缩放 \(Int(webView.pageZoom*100))%" } }
    @objc func resetZoom() { if !capturing { webView.pageZoom = 1; status.stringValue = "缩放 100%" } }
    @objc func openFile() {
        guard !capturing else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.html,.pdf,.plainText,.image,.init(filenameExtension:"webarchive")!]; panel.canChooseDirectories = false
        if panel.runModal() == .OK,let url = panel.url { load(url) }
    }
    @objc func suspendOthers() {
        guard !capturing else { return }
        let alert = NSAlert(); alert.messageText = "释放其他标签页？"; alert.informativeText = "未提交的表单和页面状态会丢失，再次打开时重新加载。"; alert.addButton(withTitle:"释放"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn { for (i,t) in tabs.enumerated() where i != activeIndex { t.release() }; renderTabs(); status.stringValue = "其他标签页已释放" }
    }
}

final class WeakCaptureHandler: NSObject, WKScriptMessageHandler {
    weak var owner:BrowserWindow?
    init(_ owner:BrowserWindow) { self.owner = owner }
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let owner,message.webView === owner.activeWebView,let data = message.body as? [String:Any] else { return }
        if data["type"] as? String == "interaction",!owner.selecting,!owner.capturing,let step = data["step"] as? [String:Any],let document = data["documentID"] as? String,let view = message.webView {
            owner.interactionRecording?.receive(step,document:document,view:view);return
        }
        guard owner.selecting else { return }
        if data["type"] as? String == "selection-changed",let description = data["description"] as? String {
            owner.selectionDescription = String(description.prefix(240))+" · ↑ 父级 / ↓ 子级 · Enter 捕获"; owner.syncCaptureBar(); return
        }
        if data["type"] as? String == "selected" { owner.selecting = false; owner.performCapture(mode:"element") }
        if data["type"] as? String == "cancelled" { owner.selecting = false; owner.status.stringValue = "已取消捕获"; owner.syncChrome() }
    }
}
