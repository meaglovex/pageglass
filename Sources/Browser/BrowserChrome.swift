import AppKit
import WebKit

extension BrowserWindow {
    func buildInterface() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 0; root.alignment = .leading; root.detachesHiddenViews = true
        window?.contentView = root
        let header = HeaderBackground(); header.wantsLayer = true
        let scroll = tabScroll; scroll.drawsBackground = false; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        // This scroll view deliberately occupies the full-size titlebar area.
        // Automatic titlebar insets can exclude every visible tab from hit testing.
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init()
        scroll.contentView = TabClipView(); scroll.contentView.drawsBackground = false
        scroll.documentView = tabRow; scroll.translatesAutoresizingMaskIntoConstraints = false
        tabRow.translatesAutoresizingMaskIntoConstraints = false; tabRow.spacing = 0
        header.addSubview(scroll)
        let newTabButton = tool("plus","新建标签页（⌘T）",#selector(newTab))
        let tabSearch = tool("chevron.down","搜索标签页",#selector(showTabList(_:)))
        for view in [newTabButton,tabSearch] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }
        tabScrollWidth = scroll.widthAnchor.constraint(equalToConstant:230); tabScrollWidth?.isActive = true
        NSLayoutConstraint.activate([
            tabSearch.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-8),tabSearch.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            newTabButton.leadingAnchor.constraint(equalTo:scroll.trailingAnchor,constant:4),newTabButton.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            newTabButton.trailingAnchor.constraint(lessThanOrEqualTo:tabSearch.leadingAnchor,constant:-4),
            scroll.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:78),scroll.topAnchor.constraint(equalTo:header.topAnchor,constant:4),scroll.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-3),tabRow.heightAnchor.constraint(equalTo:scroll.heightAnchor)
        ])
        let toolbar = ChromeStackView(); toolbar.spacing = 6; toolbar.edgeInsets = NSEdgeInsets(top:5,left:8,bottom:5,right:8)
        toolbar.wantsLayer = true
        configure(back,"chevron.left","后退",#selector(goBack)); configure(forward,"chevron.right","前进",#selector(goForward)); configure(refresh,"arrow.clockwise","重新加载",#selector(reload))
        let home = tool("house","主页",#selector(goHome))
        let omnibox = ChromeStackView(); self.omnibox = omnibox; omnibox.spacing = 5; omnibox.edgeInsets = NSEdgeInsets(top:0,left:8,bottom:0,right:6)
        omnibox.wantsLayer = true; omnibox.cornerRadius = 16; omnibox.surfaceColor = .windowBackgroundColor; omnibox.showsBorder = true
        configure(siteButton,"lock","网站信息",#selector(siteInfo)); configure(bookmarkButton,"star","添加或移除书签（⌘D）",#selector(toggleBookmark))
        address.placeholderString = "搜索或输入网址"; address.font = .systemFont(ofSize:13); address.isBordered = false; address.drawsBackground = false; address.focusRingType = .none
        address.target = self; address.action = #selector(navigate); address.delegate = self; address.setAccessibilityLabel("地址栏")
        address.setContentHuggingPriority(.defaultLow,for:.horizontal)
        omnibox.addArrangedSubview(siteButton); omnibox.addArrangedSubview(address); omnibox.addArrangedSubview(bookmarkButton)
        configure(recordInteraction,"record.circle","记录交互（⌘⇧I）",#selector(toggleInteractionRecording))
        configure(pick,"viewfinder","捕获元素（⌘⇧C）",#selector(selectElement),width:74); pick.title = "捕获"; pick.imagePosition = .imageLeading; pick.font = BrowserStyle.body; configure(captureAll,"rectangle.dashed","捕获全部（⌘⇧A）",#selector(capturePage))
        configure(downloadButton,"arrow.down.circle","下载（⌘J）",#selector(showDownloads))
        configure(captureMenuButton,"chevron.down","更多捕获操作",#selector(showCaptureMenu(_:)))
        let captureGroup = ChromeStackView(views:[pick,captureMenuButton]); captureGroup.spacing = 0
        captureGroup.cornerRadius = BrowserStyle.cornerRadius; captureGroup.surfaceColor = .windowBackgroundColor; captureGroup.showsBorder = true
        let profile = tool(privateBrowsing ? "eye.slash" : "gearshape",privateBrowsing ? "无痕窗口" : "浏览器设置",#selector(showSettings))
        let more = tool("ellipsis","更多",#selector(showMore(_:)))
        toolbarTools = [.home:home,.downloads:downloadButton,.settings:profile,.recording:recordInteraction]
        address.widthAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        for v in [back,forward,refresh,home,omnibox,captureGroup,recordInteraction,downloadButton,profile,more] { toolbar.addArrangedSubview(v) }
        omnibox.heightAnchor.constraint(equalToConstant:32).isActive = true
        bookmarkRow.spacing = 12; bookmarkRow.edgeInsets = NSEdgeInsets(top:3,left:16,bottom:3,right:16)
        buildFindBar(); buildErrorBar(); buildCaptureBar()
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = 1; progress.isHidden = true
        for v in [header,toolbar,bookmarkRow,progress,findBar,errorBar,content] {
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
        captureBar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(captureBar)
        let barWidth = captureBar.widthAnchor.constraint(equalToConstant:620); barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([barWidth,captureBar.widthAnchor.constraint(lessThanOrEqualTo:content.widthAnchor,constant:-24),captureBar.centerXAnchor.constraint(equalTo:content.centerXAnchor),captureBar.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-44)])
        NSLayoutConstraint.activate([status.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),status.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12),status.widthAnchor.constraint(lessThanOrEqualTo:content.widthAnchor,constant:-24)])
        renderBookmarks(); updateToolbarLayout()
    }
    func configure(_ button:NSButton,_ symbol:String,_ label:String,_ action:Selector,width:CGFloat = BrowserStyle.controlSize) {
        button.title = ""; button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label); button.imagePosition = .imageOnly
        button.isBordered = false; button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:BrowserStyle.iconSize,weight:.regular)
        button.widthAnchor.constraint(equalToConstant:width).isActive = true; button.heightAnchor.constraint(equalToConstant:BrowserStyle.controlSize).isActive = true
    }
    func tool(_ symbol:String,_ label:String,_ action:Selector)->NSButton { let b = ChromeButton(); configure(b,symbol,label,action); return b }
    func updateToolbarLayout() {
        let compact = (window?.frame.width ?? 1280) < 1040
        let visible = Set(store.state.settings.toolbarTools ?? ToolbarTool.defaults)
        for (tool,view) in toolbarTools {
            let active = (tool == .recording && interactionRecording?.isRecording == true) || (tool == .downloads && downloadRecords.values.contains { $0.state.hasPrefix("下载中") || $0.state == "等待保存" })
            view.isHidden = !active && (!visible.contains(tool.rawValue) || (compact && tool != .downloads))
        }
    }
    func updateTabAppearance(_ tab:BrowserTab) {
        tabButtons[tab.id]?.update(tab,selected:tabs.indices.contains(activeIndex) && tabs[activeIndex].id == tab.id)
    }
    func renderTabs(revealActive:Bool = false) {
        let ids = Set(tabs.map(\.id))
        for id in Array(tabButtons.keys) where !ids.contains(id) {
            if let view = tabButtons.removeValue(forKey:id) { tabRow.removeArrangedSubview(view); view.removeFromSuperview() }
            tabWidths.removeValue(forKey:id)
        }
        let available = max(200,(window?.frame.width ?? 1280)-154)
        let width = min(230,max(110,available/Double(max(1,tabs.count))))
        tabScrollWidth?.constant = min(available,width*Double(max(1,tabs.count)))
        for (index,tab) in tabs.enumerated() {
            let item:TabButton
            if let existing = tabButtons[tab.id] { item = existing }
            else {
                item = TabButton(tab:tab)
                let tabID = tab.id
                item.activate = { [weak self] in guard let self,let i = tabs.firstIndex(where:{$0.id == tabID}) else { return }; activate(i) }
                item.close = { [weak self] in guard let self,let i = tabs.firstIndex(where:{$0.id == tabID}) else { return }; close(at:i) }
                item.contextMenu = { [weak self] in self?.tabMenu(tabID) ?? NSMenu() }
                item.drop = { [weak self] point in
                    guard let self, tabScroll.contentView.bounds.contains(tabScroll.contentView.convert(point,from:nil)), let target = tabs.first(where: { tab in
                        guard let view = self.tabButtons[tab.id] else { return false }
                        return view.bounds.contains(view.convert(point,from:nil))
                    }) else { return }
                    if let targetView = tabButtons[target.id] {
                        moveTab(tabID,relativeTo:target.id,after:targetView.convert(point,from:nil).x > targetView.bounds.midX)
                    }
                }
                tabButtons[tab.id] = item
                let constraint = item.widthAnchor.constraint(equalToConstant:width); constraint.isActive = true; tabWidths[tab.id] = constraint
                item.heightAnchor.constraint(equalToConstant:30).isActive = true
            }
            if tabRow.arrangedSubviews.count <= index || tabRow.arrangedSubviews[index] !== item {
                if tabRow.arrangedSubviews.contains(item) { tabRow.removeArrangedSubview(item) }
                tabRow.insertArrangedSubview(item,at:index)
            }
            item.update(tab,selected:index == activeIndex); tabWidths[tab.id]?.constant = width
        }
        if revealActive,tabs.indices.contains(activeIndex),let selected = tabButtons[tabs[activeIndex].id] {
            window?.contentView?.layoutSubtreeIfNeeded(); selected.scrollToVisible(selected.bounds)
        }
    }
    func renderBookmarks(force:Bool = false) {
        let width = window?.frame.width ?? 1280, visible = store.state.settings.showBookmarksBar
        guard force || renderedBookmarks != store.state.bookmarks || renderedBookmarkWidth != width || renderedBookmarksVisible != visible else { return }
        renderedBookmarks = store.state.bookmarks; renderedBookmarkWidth = width; renderedBookmarksVisible = visible
        bookmarkPopover?.close()
        for v in bookmarkRow.arrangedSubviews { bookmarkRow.removeArrangedSubview(v); v.removeFromSuperview() }
        bookmarkRow.isHidden = !store.state.settings.showBookmarksBar
        guard !bookmarkRow.isHidden else { return }
        var remaining = max(0,(window?.frame.width ?? 1280)-150)
        overflowBookmarks = []
        for record in store.state.bookmarks {
            let width = min(180,max(60,(String(record.title.prefix(40)) as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width+34))
            if !overflowBookmarks.isEmpty || remaining < width+12 { overflowBookmarks.append(record); continue }
            let button = bookmarkButton(for:record); bookmarkRow.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant:width).isActive = true; remaining -= width+12
        }
        if !overflowBookmarks.isEmpty { bookmarkRow.addArrangedSubview(tool("chevron.right.2","更多书签",#selector(showBookmarkOverflow(_:)))) }
        let all = BookmarkBarButton(title:"所有书签",target:self,action:#selector(showBookmarks)); all.isBordered = false; all.font = .systemFont(ofSize:11); all.contextMenu = { [weak self] in self?.bookmarkMenu(id:nil) ?? NSMenu() }; bookmarkRow.addArrangedSubview(all)
    }
    func bookmarkButton(for record:PageRecord)->BookmarkBarButton {
        let button = BookmarkBarButton(title:String(record.title.prefix(120)),target:self,action:#selector(bookmarkClicked(_:))); button.isBordered = false
        button.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString); button.toolTip = record.url; button.font = .systemFont(ofSize:11); button.lineBreakMode = .byTruncatingTail
        button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown; button.alignment = .left
        button.image = NSImage(systemSymbolName:"globe",accessibilityDescription:nil)
        if let page = URL(string:record.url) {
            button.image = favicons.cached(for:page) ?? button.image
            Task { @MainActor [weak self,weak button] in
                guard let self,let icon = await favicons.image(for:page) else { return }; button?.image = icon
            }
        }
        button.contextMenu = { [weak self] in self?.bookmarkMenu(id:record.id) ?? NSMenu() }
        return button
    }
    @objc func bookmarkClicked(_ button:NSButton) {
        bookmarkPopover?.close()
        if let record = store.state.bookmarks.first(where:{$0.id.uuidString == button.identifier?.rawValue}),let url = URL(string:record.url) { load(url) }
    }
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
    func show(_ text:String,persistent:Bool) { stringValue = text; if persistent { hideWork?.cancel() } }
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
