import AppKit

final class BookmarkListController:NSViewController,NSTableViewDataSource,NSTableViewDelegate {
    weak var browser:BrowserWindow?
    let records:[PageRecord]
    let table = BrowserListTable()
    init(browser:BrowserWindow,records:[PageRecord]) {
        self.browser = browser; self.records = records; super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidAppear() { super.viewDidAppear(); focusFirstRow() }
    override func loadView() {
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:316,height:min(400,CGFloat(records.count)*32)))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = true; scroll.backgroundColor = .controlBackgroundColor
        let column = NSTableColumn(identifier:.init("bookmark"))
        column.width = scroll.contentSize.width; column.resizingMask = .autoresizingMask
        table.frame = NSRect(x:0,y:0,width:scroll.contentSize.width,height:CGFloat(records.count)*32)
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 30; table.intercellSpacing = NSSize(width:0,height:2)
        table.style = .plain; table.backgroundColor = .controlBackgroundColor; table.allowsMultipleSelection = false
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(openSelected)
        table.setAccessibilityLabel("更多书签")
        table.openSelection = { [weak self] in self?.openSelected() }
        table.dismiss = { [weak self] in self?.browser?.dismissBookmarkOverflow() }
        table.contextMenu = { [weak self] row in
            guard let self,self.records.indices.contains(row) else { return nil }
            return self.browser?.bookmarkMenu(id:self.records[row].id)
        }
        scroll.documentView = table; view = scroll; table.reloadData()
        if !records.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
    }
    func focusFirstRow() {
        view.layoutSubtreeIfNeeded()
        guard !records.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        table.scrollRowToVisible(0); view.window?.makeKey(); view.window?.makeFirstResponder(table)
    }
    func numberOfRows(in tableView:NSTableView)->Int { records.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let record = records[row], cell = NSTableCellView()
        cell.frame = NSRect(x:0,y:0,width:tableView.bounds.width,height:30); cell.toolTip = record.url
        let icon = NSImageView(frame:NSRect(x:10,y:7,width:16,height:16))
        icon.image = NSImage(systemSymbolName:"globe",accessibilityDescription:nil); icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString:record.title)
        title.font = .systemFont(ofSize:12); title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x:34,y:7,width:max(0,tableView.bounds.width-46),height:17); title.autoresizingMask = [.width]
        cell.imageView = icon; cell.textField = title; cell.addSubview(icon); cell.addSubview(title)
        if let browser,let url = URL(string:record.url) {
            icon.image = browser.favicons.cached(for:url) ?? icon.image
            Task { @MainActor [weak browser,weak icon] in
                guard let image = await browser?.favicons.image(for:url) else { return }; icon?.image = image
            }
        }
        return cell
    }
    @objc func openSelected() {
        guard records.indices.contains(table.selectedRow),let browser,
              let record = browser.store.state.bookmarks.first(where:{$0.id == records[table.selectedRow].id}),
              let url = URL(string:record.url) else { return }
        browser.dismissBookmarkOverflow(); browser.load(url)
    }
}
