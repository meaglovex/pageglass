import AppKit

final class LibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Mode:Int { case bookmarks,history,downloads }
    weak var browser:BrowserWindow?
    var mode = Mode.bookmarks
    let tabs = NSSegmentedControl(labels:["书签","历史记录","下载"],trackingMode:.selectOne,target:nil,action:nil)
    let search = NSSearchField()
    let table = NSTableView()
    let emptyState = PanelEmptyState()
    private let heading = NSTextField(labelWithString:"书签")
    private let listScroll = NSScrollView()
    let detail = NSTextField(labelWithString:"")
    let primary = NSButton(), secondary = NSButton(), cancel = NSButton(), edit = NSButton()
    var pages: [PageRecord] = [], downloads: [DownloadRecord] = []
    var observer: NSObjectProtocol?
    init(browser:BrowserWindow) {
        self.browser = browser
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:540),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "资料库"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:600,height:400)
        super.init(window:window); window.appearance = browser.window?.appearance; window.center()
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 14; root.edgeInsets = NSEdgeInsets(top:20,left:20,bottom:20,right:20); window.contentView = root
        heading.font = BrowserStyle.title
        tabs.target = self; tabs.action = #selector(selectSection)
        search.placeholderString = "搜索标题或网址"; search.target = self; search.action = #selector(searchChanged); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索资料记录")
        let top = NSStackView(views:[tabs,search]); top.spacing = 16
        search.widthAnchor.constraint(greaterThanOrEqualToConstant:140).isActive = true
        listScroll.hasVerticalScroller = true; listScroll.borderType = .noBorder
        let title = NSTableColumn(identifier:.init("title")); title.title = "名称"; title.width = 450
        let date = NSTableColumn(identifier:.init("date")); date.title = "时间 / 状态"; date.width = 210
        table.addTableColumn(title); table.addTableColumn(date); table.rowHeight = 50; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.usesAlternatingRowBackgroundColors = true; table.setAccessibilityLabel("资料列表")
        let context = NSMenu();context.delegate = self;table.menu = context
        listScroll.documentView = table
        let list = emptyState.install(over:listScroll)
        detail.font = BrowserStyle.caption; detail.textColor = BrowserStyle.supportingText
        primary.title = "打开"; primary.target = self; primary.action = #selector(openSelected); primary.bezelStyle = .rounded
        primary.bezelColor = .controlAccentColor
        secondary.target = self; secondary.action = #selector(secondaryAction); secondary.bezelStyle = .rounded
        cancel.title = "取消下载"; cancel.target = self; cancel.action = #selector(cancelSelected); cancel.bezelStyle = .rounded
        edit.title = "编辑书签…";edit.target = self;edit.action = #selector(editSelected);edit.bezelStyle = .rounded
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let bottom = NSStackView(views:[detail,spacer,cancel,edit,secondary,primary]); bottom.spacing = 10
        for view in [heading,top,list,bottom] { root.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive = true }
        list.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        observer = NotificationCenter.default.addObserver(forName:BrowserStore.changed,object:browser.store,queue:.main) { [weak self] _ in self?.refresh() }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func show(_ mode:Mode) { self.mode = mode; tabs.selectedSegment = mode.rawValue; search.stringValue = ""; refresh(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    @objc func selectSection() { mode = Mode(rawValue:tabs.selectedSegment) ?? .bookmarks; refresh() }
    @objc func searchChanged() { refresh() }
    @objc private func clearSearch() { search.stringValue = ""; refresh(); window?.makeFirstResponder(search) }
    @objc func closeTab() { close() }
    func refresh() {
        guard let browser else { return }
        let selectedID: UUID? = mode == .downloads ? (downloads.indices.contains(table.selectedRow) ? downloads[table.selectedRow].id : nil) : (pages.indices.contains(table.selectedRow) ? pages[table.selectedRow].id : nil)
        let q = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        pages = (mode == .bookmarks ? browser.store.state.bookmarks : browser.store.state.history).filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
        downloads = (browser.privateBrowsing || browser.isTesting ? Array(browser.downloadRecords.values).sorted{$0.date>$1.date} : browser.store.state.downloads).filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if let selectedID,let row = (mode == .downloads ? downloads.map(\.id) : pages.map(\.id)).firstIndex(of:selectedID) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        secondary.title = mode == .bookmarks ? "移除书签" : mode == .history ? "清除历史…" : "在 Finder 中显示"
        primary.title = mode == .downloads ? "打开文件" : "打开"
        cancel.isHidden = mode != .downloads;edit.isHidden = mode != .bookmarks
        detail.stringValue = mode == .history && browser.privateBrowsing ? "无痕浏览不记录新的访问" : "\(mode == .downloads ? downloads.count : pages.count) 条记录"
        heading.stringValue = mode == .bookmarks ? "书签" : mode == .history ? "历史记录" : "下载"
        window?.title = heading.stringValue
        search.placeholderString = mode == .downloads ? "搜索文件名称" : "搜索标题或网址"
        let empty = mode == .downloads ? downloads.isEmpty : pages.isEmpty
        emptyState.isHidden = !empty; listScroll.isHidden = empty
        if empty {
            if browser.store.error != nil {
                emptyState.show("资料读取失败",message:"原数据已保留。请检查本机资料文件后重新打开 Pageglass。",symbol:"exclamationmark.triangle")
            } else if !q.isEmpty {
                emptyState.show("没有匹配的\(heading.stringValue)",message:"试试其他关键词，或清除搜索查看全部记录。",symbol:"magnifyingglass",actionTitle:"清除搜索",target:self,selector:#selector(clearSearch))
            } else {
                let title = mode == .bookmarks ? "还没有书签" : mode == .history ? "还没有浏览记录" : "还没有下载记录"
                let hint = mode == .bookmarks ? "打开网页后，点击地址栏星标或按 ⌘D 添加书签。" : mode == .history ? (browser.privateBrowsing ? "无痕浏览不会记录新的访问。" : "访问网页后，可以在这里搜索并重新打开。") : "下载文件后，可在这里查看进度、打开文件或在 Finder 中定位。"
                emptyState.show(title,message:hint,symbol:mode == .bookmarks ? "bookmark" : mode == .history ? "clock" : "arrow.down.circle")
            }
        }
        selectionChanged()
    }
    func numberOfRows(in tableView:NSTableView)->Int { mode == .downloads ? downloads.count : pages.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let field = NSTextField(wrappingLabelWithString:""); field.font = .systemFont(ofSize:12); field.maximumNumberOfLines = 2; field.lineBreakMode = .byTruncatingMiddle
        if mode == .downloads {
            let item = downloads[row]; field.stringValue = tableColumn?.identifier.rawValue == "title" ? item.name + "\n" + (item.path ?? item.source) : item.state
        } else {
            let item = pages[row]; field.stringValue = tableColumn?.identifier.rawValue == "title" ? item.title + "\n" + item.url : item.date.formatted(date:.abbreviated,time:.shortened)
        }
        return field
    }
    func tableViewSelectionDidChange(_ notification:Notification) { selectionChanged() }
    private func selectionChanged() {
        let selected = table.selectedRow >= 0
        edit.isEnabled = selected && mode == .bookmarks
        primary.isEnabled = selected; secondary.isEnabled = mode == .history ? browser?.store.state.history.isEmpty == false : selected
        cancel.isEnabled = selected && mode == .downloads && downloads.indices.contains(table.selectedRow) && downloads[table.selectedRow].state.hasPrefix("下载中")
        if mode == .downloads {
            let item = downloads.indices.contains(table.selectedRow) ? downloads[table.selectedRow] : nil
            primary.isEnabled = item?.state == "已完成" && item?.path != nil
            secondary.isEnabled = item?.path != nil
        }
    }
    func menuNeedsUpdate(_ menu:NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard mode == .bookmarks,pages.indices.contains(row),let browser else { return }
        let source = browser.bookmarkMenu(id:pages[row].id)
        for item in source.items { source.removeItem(item);menu.addItem(item) }
    }
    @objc func editSelected() {
        guard mode == .bookmarks,pages.indices.contains(table.selectedRow) else { return }
        browser?.editBookmark(id:pages[table.selectedRow].id)
    }
    @objc func openSelected() {
        let index = table.selectedRow
        if mode == .downloads {
            guard downloads.indices.contains(index),let path = downloads[index].path,downloads[index].state == "已完成" else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath:path))
        } else if pages.indices.contains(index),let url = URL(string:pages[index].url) { browser?.openTab(url); browser?.window?.makeKeyAndOrderFront(nil) }
    }
    @objc func secondaryAction() {
        guard let browser else { return }; let index = table.selectedRow
        if mode == .bookmarks, pages.indices.contains(index) { browser.store.removeBookmark(id:pages[index].id) }
        if mode == .history {
            let alert = NSAlert(); alert.messageText = "清除所有浏览历史？"; alert.informativeText = "此操作不能撤销。书签、下载文件及网站登录不会被删除。"; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"清除历史")
            if alert.runModal() == .alertSecondButtonReturn { browser.store.clearHistory() }
        }
        if mode == .downloads,downloads.indices.contains(index),let path = downloads[index].path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) }
    }
    @objc func cancelSelected() { let index = table.selectedRow; if downloads.indices.contains(index) { browser?.cancelDownload(id:downloads[index].id) } }
}
