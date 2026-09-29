import AppKit

final class BookmarkBarButton:NSButton {
    var contextMenu:(()->NSMenu)?
    override func menu(for event:NSEvent)->NSMenu? { contextMenu?() }
}

extension BrowserWindow {
    func bookmarkMenu(id:UUID?)->NSMenu {
        let menu = NSMenu()
        func add(_ title:String,_ action:Selector) {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:"")
            item.target = self;item.representedObject = id?.uuidString;menu.addItem(item)
        }
        if let id,store.state.bookmarks.contains(where:{$0.id == id}) {
            add("在新标签页中打开",#selector(openBookmarkFromMenu(_:)))
            menu.addItem(.separator())
            add("编辑书签…",#selector(editBookmarkFromMenu(_:)))
            add("移除书签",#selector(removeBookmarkFromMenu(_:)))
            menu.addItem(.separator())
        }
        add("管理书签…",#selector(showBookmarks))
        return menu
    }
    private func bookmarkID(_ item:NSMenuItem)->UUID? { (item.representedObject as? String).flatMap(UUID.init(uuidString:)) }
    @objc func openBookmarkFromMenu(_ item:NSMenuItem) {
        guard let id = bookmarkID(item),let record = store.state.bookmarks.first(where:{$0.id == id}),let url = URL(string:record.url) else { return }
        openTab(url)
    }
    @objc func removeBookmarkFromMenu(_ item:NSMenuItem) { if let id = bookmarkID(item) { store.removeBookmark(id:id) } }
    @objc func editBookmarkFromMenu(_ item:NSMenuItem) { if let id = bookmarkID(item) { editBookmark(id:id) } }
    func editBookmark(id:UUID) {
        guard let record = store.state.bookmarks.first(where:{$0.id == id}) else { return }
        bookmarkPopover?.close()
        let alert = NSAlert();alert.messageText = "编辑书签"
        alert.informativeText = "修改书签名称和网址。";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
        let title = NSTextField(string:record.title),address = NSTextField(string:record.url)
        title.setAccessibilityLabel("书签名称");address.setAccessibilityLabel("书签网址")
        let fields = NSStackView(views:[NSTextField(labelWithString:"名称"),title,NSTextField(labelWithString:"网址"),address])
        fields.orientation = .vertical;fields.alignment = .leading;fields.spacing = 6
        fields.frame = NSRect(x:0,y:0,width:360,height:104)
        for field in [title,address] { field.widthAnchor.constraint(equalToConstant:360).isActive = true }
        alert.accessoryView = fields;alert.window.initialFirstResponder = title
        while alert.runModal() == .alertFirstButtonReturn {
            if store.updateBookmark(id:id,title:title.stringValue,url:address.stringValue) { return }
            guard store.state.bookmarks.contains(where:{$0.id == id}) else { return }
            alert.informativeText = "请输入完整的网址（https://、http:// 或 file://）。"
            alert.window.initialFirstResponder = address
        }
    }
}
