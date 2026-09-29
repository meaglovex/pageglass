import AppKit

final class LibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Mode:Int { case bookmarks,history,downloads }
    weak var browser:BrowserWindow?
    var mode = Mode.bookmarks
    let tabs = NSSegmentedControl(labels:["书签","历史记录","下载"],trackingMode:.selectOne,target:nil,action:nil)
    let search = NSSearchField()
    let table = NSTableView()
    let detail = NSTextField(labelWithString:"")
    let primary = NSButton(), secondary = NSButton(), cancel = NSButton(), edit = NSButton()
    var pages: [PageRecord] = [], downloads: [DownloadRecord] = []
    var observer: NSObjectProtocol?
    init(browser:BrowserWindow) {
        self.browser = browser
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:540),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "资料库"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:600,height:350)
        super.init(window:window); window.appearance = browser.window?.appearance; window.center()
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 14; root.edgeInsets = NSEdgeInsets(top:20,left:20,bottom:20,right:20); window.contentView = root
        tabs.target = self; tabs.action = #selector(selectSection)
        search.placeholderString = "搜索标题或网址"; search.target = self; search.action = #selector(searchChanged); search.sendsSearchStringImmediately = true
        let top = NSStackView(views:[tabs,search]); top.spacing = 24
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
        let title = NSTableColumn(identifier:.init("title")); title.title = "名称"; title.width = 450
        let date = NSTableColumn(identifier:.init("date")); date.title = "时间 / 状态"; date.width = 210
        table.addTableColumn(title); table.addTableColumn(date); table.rowHeight = 50; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.usesAlternatingRowBackgroundColors = true; table.setAccessibilityLabel("资料列表")
        let context = NSMenu();context.delegate = self;table.menu = context
        scroll.documentView = table
        detail.font = .systemFont(ofSize:12); detail.textColor = .secondaryLabelColor
        primary.title = "打开"; primary.target = self; primary.action = #selector(openSelected); primary.bezelStyle = .rounded
        secondary.target = self; secondary.action = #selector(secondaryAction); secondary.bezelStyle = .rounded
        cancel.title = "取消下载"; cancel.target = self; cancel.action = #selector(cancelSelected); cancel.bezelStyle = .rounded
        edit.title = "编辑书签…";edit.target = self;edit.action = #selector(editSelected);edit.bezelStyle = .rounded
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let bottom = NSStackView(views:[detail,spacer,cancel,edit,secondary,primary]); bottom.spacing = 10
        for view in [top,scroll,bottom] { root.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        observer = NotificationCenter.default.addObserver(forName:BrowserStore.changed,object:browser.store,queue:.main) { [weak self] _ in self?.refresh() }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func show(_ mode:Mode) { self.mode = mode; tabs.selectedSegment = mode.rawValue; search.stringValue = ""; refresh(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    @objc func selectSection() { mode = Mode(rawValue:tabs.selectedSegment) ?? .bookmarks; refresh() }
    @objc func searchChanged() { refresh() }
    func refresh() {
        guard let browser else { return }
        let selectedID: UUID? = mode == .downloads ? (downloads.indices.contains(table.selectedRow) ? downloads[table.selectedRow].id : nil) : (pages.indices.contains(table.selectedRow) ? pages[table.selectedRow].id : nil)
        let q = search.stringValue
        pages = (mode == .bookmarks ? browser.store.state.bookmarks : browser.store.state.history).filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
        downloads = (browser.privateBrowsing || browser.isTesting ? Array(browser.downloadRecords.values).sorted{$0.date>$1.date} : browser.store.state.downloads).filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if let selectedID,let row = (mode == .downloads ? downloads.map(\.id) : pages.map(\.id)).firstIndex(of:selectedID) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        secondary.title = mode == .bookmarks ? "移除书签" : mode == .history ? "清除历史…" : "在 Finder 中显示"
        primary.title = mode == .downloads ? "打开文件" : "打开"
        cancel.isHidden = mode != .downloads;edit.isHidden = mode != .bookmarks
        detail.stringValue = mode == .history && browser.privateBrowsing ? "无痕浏览不记录新的访问" : "\(mode == .downloads ? downloads.count : pages.count) 条记录"
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
        primary.isEnabled = selected; secondary.isEnabled = mode == .history || selected
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
