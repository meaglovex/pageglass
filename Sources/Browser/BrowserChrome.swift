import AppKit
import WebKit

extension BrowserWindow {
    func buildInterface() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 0; root.alignment = .leading; root.detachesHiddenViews = true
        window?.contentView = root
        let header = HeaderBackground(); header.wantsLayer = true; header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = tabRow; scroll.translatesAutoresizingMaskIntoConstraints = false
        tabRow.translatesAutoresizingMaskIntoConstraints = false; tabRow.spacing = 0
        header.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:78),scroll.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-12),scroll.topAnchor.constraint(equalTo:header.topAnchor,constant:4),scroll.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-3),tabRow.heightAnchor.constraint(equalTo:scroll.heightAnchor)])
        let toolbar = NSStackView(); toolbar.spacing = 6; toolbar.edgeInsets = NSEdgeInsets(top:5,left:8,bottom:5,right:8)
        toolbar.wantsLayer = true; toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        configure(back,"chevron.left","后退",#selector(goBack)); configure(forward,"chevron.right","前进",#selector(goForward)); configure(refresh,"arrow.clockwise","重新加载",#selector(reload))
        let home = tool("house","主页",#selector(goHome))
        let omnibox = NSStackView(); omnibox.spacing = 5; omnibox.edgeInsets = NSEdgeInsets(top:0,left:8,bottom:0,right:6)
        omnibox.wantsLayer = true; omnibox.layer?.cornerRadius = 16; omnibox.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor
        configure(siteButton,"lock","网站信息",#selector(siteInfo)); configure(bookmarkButton,"star","添加或移除书签（⌘D）",#selector(toggleBookmark))
        address.placeholderString = "搜索或输入网址"; address.font = .systemFont(ofSize:13); address.isBordered = false; address.drawsBackground = false; address.focusRingType = .none
        address.target = self; address.action = #selector(navigate); address.delegate = self; address.setAccessibilityLabel("地址栏")
        address.setContentHuggingPriority(.defaultLow,for:.horizontal)
        omnibox.addArrangedSubview(siteButton); omnibox.addArrangedSubview(address); omnibox.addArrangedSubview(bookmarkButton)
        configure(recordInteraction,"record.circle","记录交互（⌘⇧I）",#selector(toggleInteractionRecording))
        configure(pick,"viewfinder","捕获元素（⌘⇧C）",#selector(selectElement)); configure(captureAll,"rectangle.dashed","捕获全部（⌘⇧A）",#selector(capturePage))
        let downloads = tool("arrow.down.circle","下载",#selector(showDownloads))
        let profile = tool(privateBrowsing ? "eye.slash" : "person.crop.circle",privateBrowsing ? "无痕窗口" : "浏览器设置",#selector(showSettings))
        let more = tool("ellipsis","更多",#selector(showMore(_:)))
        for v in [back,forward,refresh,home,omnibox,recordInteraction,pick,captureAll,downloads,profile,more] { toolbar.addArrangedSubview(v) }
        omnibox.heightAnchor.constraint(equalToConstant:32).isActive = true
        bookmarkRow.spacing = 12; bookmarkRow.edgeInsets = NSEdgeInsets(top:3,left:16,bottom:3,right:16)
        buildFindBar()
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = 1; progress.isHidden = true
        for v in [header,toolbar,bookmarkRow,progress,findBar,content] {
            root.addArrangedSubview(v); v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant:38).isActive = true
        toolbar.heightAnchor.constraint(equalToConstant:42).isActive = true
        progress.heightAnchor.constraint(equalToConstant:2).isActive = true
        content.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive = true
        status.translatesAutoresizingMaskIntoConstraints = false; status.font = .systemFont(ofSize:12); status.textColor = .labelColor
        status.drawsBackground = true; status.backgroundColor = .controlBackgroundColor; status.lineBreakMode = .byTruncatingMiddle
        status.wantsLayer = true; status.layer?.cornerRadius = 7
        content.addSubview(status)
        NSLayoutConstraint.activate([status.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),status.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12),status.widthAnchor.constraint(lessThanOrEqualTo:content.widthAnchor,constant:-24)])
        renderBookmarks()
    }
    func configure(_ button:NSButton,_ symbol:String,_ label:String,_ action:Selector) {
        button.title = ""; button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label); button.imagePosition = .imageOnly
        button.isBordered = false; button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant:28).isActive = true; button.heightAnchor.constraint(equalToConstant:28).isActive = true
    }
    func tool(_ symbol:String,_ label:String,_ action:Selector)->NSButton { let b = NSButton(); configure(b,symbol,label,action); return b }
    func renderTabs() {
        for v in tabRow.arrangedSubviews { tabRow.removeArrangedSubview(v); v.removeFromSuperview() }
        let available = max(300,(window?.frame.width ?? 1280)-120)
        let width = min(230,max(110,available/Double(max(1,tabs.count))))
        for (index,tab) in tabs.enumerated() {
            let item = TabButton(tab:tab,ownerID:id); item.selected = index == activeIndex
            let tabID = tab.id
            item.activate = { [weak self] in guard let self,let i = tabs.firstIndex(where:{$0.id == tabID}) else { return }; activate(i) }
            item.close = { [weak self] in guard let self,let i = tabs.firstIndex(where:{$0.id == tabID}) else { return }; close(at:i) }
            item.contextMenu = { [weak self] in self?.tabMenu(tabID) ?? NSMenu() }
            item.reorder = { [weak self] source in self?.moveTab(source,before:tabID) }
            tabRow.addArrangedSubview(item); item.widthAnchor.constraint(equalToConstant:width).isActive = true; item.heightAnchor.constraint(equalToConstant:30).isActive = true
        }
        tabRow.addArrangedSubview(tool("plus","新建标签页（⌘T）",#selector(newTab)))
    }
    func renderBookmarks() {
        for v in bookmarkRow.arrangedSubviews { bookmarkRow.removeArrangedSubview(v); v.removeFromSuperview() }
        bookmarkRow.isHidden = !store.state.settings.showBookmarksBar
        guard !bookmarkRow.isHidden else { return }
        for record in store.state.bookmarks.prefix(8) {
            let button = BookmarkBarButton(title:String(record.title.prefix(20)),target:self,action:#selector(bookmarkClicked(_:))); button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString); button.toolTip = record.url; button.font = .systemFont(ofSize:11)
            button.imagePosition = .imageLeading;button.imageScaling = .scaleProportionallyDown
            button.image = NSImage(systemSymbolName:"globe",accessibilityDescription:nil)
            if let page = URL(string:record.url) {
                button.image = favicons.cached(for:page) ?? button.image
                Task { @MainActor [weak self,weak button] in
                    guard let self,let icon = await favicons.image(for:page) else { return };button?.image = icon
                }
            }
            button.contextMenu = { [weak self] in self?.bookmarkMenu(id:record.id) ?? NSMenu() }
            bookmarkRow.addArrangedSubview(button)
        }
        let all = BookmarkBarButton(title:"所有书签",target:self,action:#selector(showBookmarks)); all.isBordered = false; all.font = .systemFont(ofSize:11); all.contextMenu = { [weak self] in self?.bookmarkMenu(id:nil) ?? NSMenu() }; bookmarkRow.addArrangedSubview(all)
    }
    @objc func bookmarkClicked(_ button:NSButton) { if let record = store.state.bookmarks.first(where:{$0.id.uuidString == button.identifier?.rawValue}),let url = URL(string:record.url) { load(url) } }
    func buildFindBar() {
        findBar.isHidden = true; findBar.spacing = 8; findBar.edgeInsets = NSEdgeInsets(top:6,left:16,bottom:6,right:12)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        findField.placeholderString = "在页面中查找"; findField.target = self; findField.action = #selector(findNext); findField.sendsSearchStringImmediately = true
        findField.widthAnchor.constraint(equalToConstant:240).isActive = true; findField.setAccessibilityLabel("查找文本")
        findResult.font = .systemFont(ofSize:11); findResult.textColor = .secondaryLabelColor
        for v in [spacer,findField,findResult,tool("chevron.up","上一个匹配",#selector(findPrevious)),tool("chevron.down","下一个匹配",#selector(findNext)),tool("xmark","关闭查找",#selector(closeFind))] { findBar.addArrangedSubview(v) }
    }
    @objc func findInPage() { findBar.isHidden = false; window?.makeFirstResponder(findField); findField.selectText(nil) }
    @objc func closeFind() { findBar.isHidden = true; findField.stringValue = ""; findResult.stringValue = ""; webView.find("",configuration:WKFindConfiguration()) { _ in }; window?.makeFirstResponder(webView) }
    @objc func findNext() { find(backwards:false) }
    @objc func findPrevious() { find(backwards:true) }
    private func find(backwards:Bool) {
        let config = WKFindConfiguration(); config.wraps = true; config.backwards = backwards
        webView.find(findField.stringValue,configuration:config) { [weak self] result in self?.findResult.stringValue = result.matchFound ? "已找到" : "未找到" }
    }
}

final class BrowserNotice: NSTextField {
    private var hideWork: DispatchWorkItem?
    override var stringValue:String {
        didSet {
            hideWork?.cancel()
            isHidden = stringValue.isEmpty || stringValue.hasPrefix("就绪") || stringValue == "正在加载…"
            guard !isHidden else { return }
            let work = DispatchWorkItem { [weak self] in self?.isHidden = true }; hideWork = work
            DispatchQueue.main.asyncAfter(deadline:.now()+8,execute:work)
        }
    }
}
