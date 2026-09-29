import AppKit

extension BrowserWindow {
    @objc func showTabList(_ sender:NSButton) {
        bookmarkPopover?.close()
        tabPopover?.close()
        let controller = TabListController(browser:self)
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        tabPopover = popover; popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)
        controller.view.window?.makeFirstResponder(controller.search)
    }
    @objc func showBookmarkOverflow(_ sender:NSButton) {
        if bookmarkPopover?.isShown == true { dismissBookmarkOverflow(); return }
        guard !overflowBookmarks.isEmpty else { return }
        tabPopover?.close()
        let controller = BookmarkListController(browser:self,records:overflowBookmarks)
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        bookmarkPopover = popover; popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)
    }
    func dismissBookmarkOverflow() {
        bookmarkPopover?.close()
        if let view = activeWebView { window?.makeFirstResponder(view) }
    }
}

final class TabListController:NSViewController,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    weak var browser:BrowserWindow?
    let search = NSSearchField()
    let table = NSTableView()
    var matches:[BrowserTab] = []
    init(browser:BrowserWindow) { self.browser = browser; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:360,height:360))
        search.placeholderString = "搜索标签标题或网址"; search.setAccessibilityLabel("搜索标签页")
        search.delegate = self; search.frame = NSRect(x:10,y:320,width:340,height:28); search.autoresizingMask = [.width,.minYMargin]
        view.addSubview(search)
        table.addTableColumn(NSTableColumn(identifier:.init("tab"))); table.headerView = nil; table.rowHeight = 48
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(openSelected)
        table.setAccessibilityLabel("标签页列表")
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:360,height:312)); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width,.height]; scroll.documentView = table
        view.addSubview(scroll); refresh()
    }
    func refresh() {
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        matches = browser?.tabs.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false) } ?? []
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
    }
    func numberOfRows(in tableView:NSTableView)->Int { matches.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let tab = matches[row], cell = NSTableCellView()
        cell.frame = NSRect(x:0,y:0,width:tableView.bounds.width,height:48)
        let title = NSTextField(labelWithString:tab.title), url = NSTextField(labelWithString:tab.url?.host ?? "新标签页")
        title.font = .systemFont(ofSize:12,weight:.medium); url.font = .systemFont(ofSize:11); url.textColor = .secondaryLabelColor
        for (field,y) in [(title,CGFloat(25)),(url,CGFloat(7))] { field.frame = NSRect(x:12,y:y,width:326,height:16); field.autoresizingMask = [.width]; field.lineBreakMode = .byTruncatingTail; cell.addSubview(field) }
        return cell
    }
    func controlTextDidChange(_ notification:Notification) { refresh() }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { browser?.tabPopover?.close(); return true }
        let offset = selector == #selector(NSResponder.moveDown(_:)) ? 1 : selector == #selector(NSResponder.moveUp(_:)) ? -1 : 0
        guard offset != 0,!matches.isEmpty else { return false }
        let row = min(matches.count-1,max(0,table.selectedRow+offset)); table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row); return true
    }
    @objc func openSelected() {
        guard matches.indices.contains(table.selectedRow),let browser,let index = browser.tabs.firstIndex(where:{$0.id == matches[table.selectedRow].id}) else { return }
        browser.tabPopover?.close(); browser.activate(index)
    }
}

final class AddressSuggestionButton:NSButton {
    var heading = "", detail = "", isSelected = false
    override func draw(_ dirtyRect:NSRect) {
        if isSelected { NSColor.selectedContentBackgroundColor.setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6).fill() }
        let primary:NSColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        let secondary:NSColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (heading as NSString).draw(in:NSRect(x:10,y:bounds.height-23,width:bounds.width-20,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:primary,.paragraphStyle:style])
        (detail as NSString).draw(in:NSRect(x:10,y:6,width:bounds.width-20,height:16),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:secondary,.paragraphStyle:style])
    }
}
