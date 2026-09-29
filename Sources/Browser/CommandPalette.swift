import AppKit

struct QuickAction {
    enum Destination { case tab(UUID), url(URL), command(Selector) }
    let group:String, title:String, detail:String
    let destination:Destination
}

@MainActor
enum QuickActions {
    static func matches(_ query:String,browser:BrowserWindow)->[QuickAction] {
        let terms = query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        func includes(_ title:String,_ detail:String)->Bool { terms.allSatisfy { (title+" "+detail).localizedCaseInsensitiveContains($0) } }
        let limit = terms.isEmpty ? 5 : 12
        var rows:[QuickAction] = []
        if !browser.capturing {
            rows += browser.tabs.filter { includes($0.title,$0.url?.absoluteString ?? "") }.prefix(limit).map {
                QuickAction(group:"已开标签",title:$0.title,detail:$0.url?.absoluteString ?? "新标签页",destination:.tab($0.id))
            }
            var seen = Set<String>()
            for (group,records) in [("书签",browser.store.state.bookmarks),("历史记录",browser.store.state.history)] {
                var count = 0
                for record in records where includes(record.title,record.url) {
                    guard let url = URL(string:record.url),["http","https","file"].contains(url.scheme ?? ""),seen.insert(record.url).inserted else { continue }
                    rows.append(QuickAction(group:group,title:record.title,detail:record.url,destination:.url(url))); count += 1
                    if count == limit { break }
                }
            }
        }
        let commands:[(String,String,Selector,Bool)] = [
            ("捕获元素","⌘⇧C",#selector(BrowserWindow.selectElement),!browser.capturing),
            ("捕获已加载整页","⌘⇧A",#selector(BrowserWindow.capturePage),!browser.capturing),
            ("捕获历史","查看、复制或清理捕获",#selector(BrowserWindow.showCaptureHistory),true),
            ("浏览器设置","⌘, · 主题、工具栏与捕获",#selector(BrowserWindow.showSettings),true),
            ("下载","⌘J",#selector(BrowserWindow.showDownloads),true),
            ("新建标签页","⌘T",#selector(BrowserWindow.newTab),!browser.capturing),
            ("重新打开关闭的标签页","⌘⇧T",#selector(BrowserWindow.reopenTab),!browser.capturing && !browser.closedTabs.isEmpty),
            ("书签管理","⌘⌥B",#selector(BrowserWindow.showBookmarks),true),
            ("历史记录","⌘Y",#selector(BrowserWindow.showHistory),true),
            ("网页检查器","F12 · 开发者工具",#selector(BrowserWindow.showDeveloperTools),!browser.capturing),
            ("JavaScript 控制台","⌥⌘J",#selector(BrowserWindow.showJavaScriptConsole),!browser.capturing),
            ("输入地址","⌘L",#selector(BrowserWindow.focusAddress),!browser.capturing),
            ("在页面中查找","⌘F",#selector(BrowserWindow.findInPage),!browser.capturing)
        ]
        rows += commands.filter { $0.3 && includes($0.0,$0.1) }.map { QuickAction(group:"操作",title:$0.0,detail:$0.1,destination:.command($0.2)) }
        return rows
    }
}

extension BrowserWindow {
    @objc func showCommandPalette() {
        if commandPalette?.window?.isVisible == true { commandPalette?.dismiss(restoreFocus:true); return }
        dismissSuggestions(); tabPopover?.close(); bookmarkPopover?.close()
        commandPalette = CommandPaletteController(browser:self); commandPalette?.present()
    }
}

/// Local search only; selection dispatches existing browser actions and navigation.
final class CommandPaletteController:NSWindowController,NSWindowDelegate,NSSearchFieldDelegate,NSTableViewDataSource,NSTableViewDelegate {
    weak var browser:BrowserWindow?
    private weak var previousFocus:NSResponder?
    let search = NSSearchField(), table = BrowserListTable()
    private(set) var results:[QuickAction] = []
    private var rows:[Int?] = [] // nil rows are section headers, never executable.
    private var closing = false
    init(browser:BrowserWindow) {
        self.browser = browser
        previousFocus = browser.window?.firstResponder === browser.address.currentEditor() ? browser.address : browser.window?.firstResponder
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:600,height:440),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        panel.title = "快速操作"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false
        super.init(window:panel); panel.delegate = self; panel.appearance = browser.window?.appearance
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top:16,left:16,bottom:12,right:16); panel.contentView = root
        search.placeholderString = "搜索标签、书签、历史或操作"; search.setAccessibilityLabel("快速操作搜索"); search.delegate = self
        table.addTableColumn(NSTableColumn(identifier:.init("result"))); table.headerView = nil; table.rowHeight = 48; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(choose); table.setAccessibilityLabel("快速操作结果")
        table.openSelection = { [weak self] in self?.choose() }
        table.dismiss = { [weak self] in self?.dismiss(restoreFocus:true) }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = table
        let hint = NSTextField(labelWithString:"↑↓ 选择   ↵ 打开   Esc 返回 · 仅搜索本机内容"); hint.font = BrowserStyle.caption; hint.textColor = BrowserStyle.supportingText
        for view in [search,scroll,hint] { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-32).isActive = true }
        search.heightAnchor.constraint(equalToConstant:32).isActive = true
        refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    func present() {
        guard let parent = browser?.window,let window else { return }
        window.setFrameOrigin(NSPoint(x:parent.frame.midX-window.frame.width/2,y:parent.frame.maxY-window.frame.height-95))
        parent.addChildWindow(window,ordered:.above); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(search)
    }
    func dismiss(restoreFocus:Bool) {
        guard !closing else { return }; closing = true
        window?.parent?.removeChildWindow(window!); window?.orderOut(nil)
        if restoreFocus,let browser,let parent = browser.window,parent.isVisible {
            parent.makeKeyAndOrderFront(nil)
            let focus = (previousFocus as? NSView)?.window === parent ? previousFocus : browser.activeWebView
            parent.makeFirstResponder(focus)
        }
    }
    @objc func showCommandPalette() { dismiss(restoreFocus:true) }
    @objc func focusAddress() { browser?.focusAddress() }
    override func cancelOperation(_ sender:Any?) { dismiss(restoreFocus:true) }
    func windowDidResignKey(_ notification:Notification) { dismiss(restoreFocus:false) }
    func refresh() {
        guard let browser else { return }
        results = QuickActions.matches(search.stringValue,browser:browser); rows = []
        var group = ""
        for (index,result) in results.enumerated() {
            if result.group != group { rows.append(nil); group = result.group }; rows.append(index)
        }
        if rows.isEmpty { rows = [nil] }
        table.reloadData()
        if let row = rows.firstIndex(where:{$0 != nil}) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(0) }
    }
    func numberOfRows(in tableView:NSTableView)->Int { rows.count }
    func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool { rows.indices.contains(row) && rows[row] != nil }
    func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat { rows[row] == nil ? 26 : 48 }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let cell = NSTableCellView(frame:NSRect(x:0,y:0,width:tableView.bounds.width,height:48))
        guard let index = rows[row] else {
            let title = results.isEmpty ? "没有匹配结果" : results[rows[row+1]!].group
            let label = NSTextField(labelWithString:title); label.font = .systemFont(ofSize:12,weight:.semibold); label.textColor = BrowserStyle.supportingText; label.frame = NSRect(x:8,y:5,width:tableView.bounds.width-16,height:18); cell.addSubview(label); return cell
        }
        let result = results[index]
        for (value,y,font,color) in [(result.title,CGFloat(25),BrowserStyle.body,NSColor.labelColor),(result.detail,CGFloat(6),BrowserStyle.caption,NSColor.secondaryLabelColor)] {
            let label = NSTextField(labelWithString:value); label.font = font; label.textColor = color; label.lineBreakMode = .byTruncatingMiddle; label.frame = NSRect(x:12,y:y,width:tableView.bounds.width-24,height:18); label.autoresizingMask = [.width]; cell.addSubview(label)
        }
        cell.setAccessibilityLabel("\(result.title)，\(result.group)，\(result.detail)"); return cell
    }
    func controlTextDidChange(_ notification:Notification) { if (search.currentEditor() as? NSTextView)?.hasMarkedText() != true { refresh() } }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(restoreFocus:true); return true }
        let offset = selector == #selector(NSResponder.moveDown(_:)) ? 1 : selector == #selector(NSResponder.moveUp(_:)) ? -1 : 0
        guard offset != 0 else { return false }
        var row = table.selectedRow+offset
        while rows.indices.contains(row) {
            if rows[row] != nil { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row); break }; row += offset
        }
        return true
    }
    @objc func choose() {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true,let browser,rows.indices.contains(table.selectedRow),let index = rows[table.selectedRow] else { return }
        let destination = results[index].destination
        dismiss(restoreFocus:true)
        switch destination {
        case .tab(let id): if !browser.capturing,let index = browser.tabs.firstIndex(where:{$0.id == id}) { browser.activate(index) }
        case .url(let url): if !browser.capturing { browser.openTab(url) }
        case .command(let selector): NSApp.sendAction(selector,to:browser,from:self)
        }
    }
}
