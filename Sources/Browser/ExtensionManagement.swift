import AppKit

extension BrowserWindow {
    @objc func showExtensions() {
        guard !privateBrowsing else { status.show("扩展只在普通窗口运行，无痕窗口不加载扩展。",persistent:true); return }
        if #available(macOS 15.4,*) {
            if extensionManager == nil { extensionManager = ExtensionManagementController(browser:self) }
            extensionManager?.showWindow(nil); extensionManager?.window?.makeKeyAndOrderFront(nil)
        } else { status.show("扩展需要 macOS 15.4 或更高版本；当前系统可继续浏览和捕获。",persistent:true) }
    }
    @objc func showExtensionMenu(_ sender:NSButton) {
        let menu = NSMenu()
        if #available(macOS 15.4,*),let runtime = extensions {
            for record in runtime.repository.state.items where runtime.contexts[record.id]?.isLoaded == true {
                let item = NSMenuItem(title:record.name,action:#selector(runExtension(_:)),keyEquivalent:""); item.target = self; item.representedObject = record.id.uuidString
                menu.addItem(item)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        let manage = NSMenuItem(title:"管理扩展…",action:#selector(showExtensions),keyEquivalent:""); manage.target = self; menu.addItem(manage)
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY),in:sender)
    }
    @objc private func runExtension(_ sender:NSMenuItem) {
        guard let string = sender.representedObject as? String,let id = UUID(uuidString:string) else { return }
        if #available(macOS 15.4,*) { extensions?.performAction(id,browser:self) }
    }
}

@available(macOS 15.4, *)
final class ExtensionManagementController:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    weak var browser:BrowserWindow?
    let runtime:ExtensionRuntime
    private let table = NSTableView(), details = NSTextField(wrappingLabelWithString:"")
    private let feedback = NSTextField(wrappingLabelWithString:"")
    private let installButton = NSButton(), updateButton = NSButton(), enableButton = NSButton(), removeButton = NSButton(), actionButton = NSButton(), optionsButton = NSButton()
    private let allowButton = NSButton(), revokeButton = NSButton(), reloadButton = NSButton(), sites = NSPopUpButton()
    private let toolbarCheck = NSButton(checkboxWithTitle:"显示在工具栏（窄窗口自动收入扩展菜单）",target:nil,action:nil)
    private var rows:[InstalledExtension] = [], observer:NSObjectProtocol?, importing = false
    private var selected:InstalledExtension? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    init(browser:BrowserWindow) {
        self.browser = browser; runtime = browser.extensions!
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "扩展"; window.minSize = NSSize(width:720,height:680); window.isReleasedWhenClosed = false; window.appearance = browser.window?.appearance
        super.init(window:window); window.center()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top:22,left:24,bottom:22,right:24); window.contentView = root
        let title = NSTextField(labelWithString:"扩展"); title.font = BrowserStyle.title
        let description = NSTextField(wrappingLabelWithString:"从本地目录或 ZIP 导入经过验证的 Manifest V3 扩展。网站权限单独授权；无痕和本地文件不运行扩展。")
        description.font = BrowserStyle.caption; description.textColor = BrowserStyle.supportingText
        for (button,title,selector) in [(installButton,"导入扩展…",#selector(importNew)),(updateButton,"更新…",#selector(updateSelected)),(enableButton,"启用",#selector(toggle)),(removeButton,"移除…",#selector(removeSelected)),(actionButton,"打开扩展",#selector(openAction)),(optionsButton,"扩展设置",#selector(openOptions)),(allowButton,"允许当前网站…",#selector(allowSite)),(revokeButton,"撤销所选网站",#selector(revokeSite)),(reloadButton,"刷新当前网页",#selector(reloadPage))] {
            button.title = title; button.bezelStyle = .rounded; button.target = self; button.action = selector
        }
        table.addTableColumn(NSTableColumn(identifier:.init("extension"))); table.headerView = nil; table.rowHeight = 52; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("已导入扩展")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:170).isActive = true
        details.font = BrowserStyle.caption; details.textColor = BrowserStyle.supportingText; details.isSelectable = true; details.maximumNumberOfLines = 9
        feedback.font = BrowserStyle.caption; feedback.textColor = BrowserStyle.supportingText; feedback.maximumNumberOfLines = 3
        sites.setAccessibilityLabel("已设置的网站权限")
        toolbarCheck.target = self; toolbarCheck.action = #selector(toggleToolbar)
        for view in [title,description,NSStackView(views:[installButton,updateButton,enableButton,removeButton]),scroll,details,toolbarCheck,NSStackView(views:[actionButton,optionsButton,allowButton]),NSStackView(views:[sites,revokeButton]),feedback,reloadButton] {
            root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive = true
        }
        observer = NotificationCenter.default.addObserver(forName:ExtensionRuntime.changed,object:runtime,queue:.main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    @objc func closeTab() { close() }
    private func refresh() {
        let id = selected?.id; rows = runtime.repository.state.items
        table.reloadData()
        if let index = rows.firstIndex(where:{$0.id == id}) ?? (rows.isEmpty ? nil : 0) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        updateDetail()
    }
    func numberOfRows(in tableView:NSTableView)->Int { rows.count }
    func tableViewSelectionDidChange(_ notification:Notification) { updateDetail() }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let record = rows[row],cell = NSTableCellView()
        let state = record.package == nil ? "已移除 · 数据保留" : runtime.errors[record.id] != nil ? "启用失败" : runtime.contexts[record.id]?.isLoaded == true ? "已启用" : "已停用"
        let label = NSTextField(labelWithString:"\(record.name)\n\(record.version) · \(state)"); label.font = BrowserStyle.body; label.lineBreakMode = .byTruncatingTail; label.frame = NSRect(x:10,y:7,width:tableView.bounds.width-20,height:38); label.autoresizingMask = [.width]; cell.addSubview(label); cell.setAccessibilityLabel(label.stringValue); return cell
    }
    private func updateDetail() {
        let usable = !runtime.busy && !importing && runtime.repository.readError == nil,record = selected
        reloadButton.isEnabled = usable && browser?.capturing == false && browser?.activeWebView?.url != nil
        installButton.isEnabled = usable
        for button in [updateButton,enableButton,removeButton,actionButton,optionsButton,allowButton,revokeButton] { button.isEnabled = usable && record != nil }
        enableButton.isEnabled = usable && record?.package != nil
        let loaded = record.flatMap { runtime.contexts[$0.id] }
        enableButton.title = loaded?.isLoaded == true ? "停用" : "启用"
        let action = record.flatMap { record in browser.flatMap { runtime.action(record.id,browser:$0) } }
        actionButton.isEnabled = usable && action?.isEnabled == true; optionsButton.isEnabled = usable && loaded?.optionsPageURL != nil
        toolbarCheck.state = record?.toolbarVisible == true ? .on : .off
        toolbarCheck.isEnabled = usable && record?.package != nil && (action != nil || loaded == nil)
        allowButton.isEnabled = usable && loaded != nil && ExtensionRuntime.sitePattern(browser?.activeWebView?.url) != nil
        sites.removeAllItems(); sites.addItems(withTitles:record?.sites.keys.sorted().map { (record?.sites[$0] == true ? "已允许 · " : "已拒绝 · ")+$0 } ?? [])
        revokeButton.isEnabled = usable && sites.numberOfItems > 0
        guard let record else { details.stringValue = runtime.repository.readError ?? "尚未安装扩展。Pageglass 不预装第三方扩展，也不默认授予全站访问。"; return }
        details.stringValue = "来源：\(record.sourceName)\n请求权限：\(record.permissions.isEmpty ? "无额外 API 权限" : record.permissions.joined(separator:", "))\n网站范围：\(record.hosts.isEmpty ? "未声明" : record.hosts.joined(separator:", "))\n\(runtime.errors[record.id] ?? "停用或撤权后，刷新网页才能清除已经改变的页面内容。")"
    }
    @objc private func importNew() { importPackage(replacing:nil) }
    @objc private func toggleToolbar() {
        guard let id = selected?.id else { return }
        do { try runtime.setToolbarVisible(toolbarCheck.state == .on,id:id) }
        catch { feedback.stringValue = error.localizedDescription; updateDetail() }
    }
    @objc private func updateSelected() { if let id = selected?.id { importPackage(replacing:id) } }
    private func importPackage(replacing id:UUID?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.message = "选择含 manifest.json 的扩展目录，或兼容 ZIP 文件"
        guard panel.runModal() == .OK,let source = panel.url else { return }
        importing = true; updateDetail(); feedback.stringValue = "正在检查扩展文件…"
        Task { @MainActor in
            var prepared:ExtensionPackage?
            defer { if let prepared { try? FileManager.default.removeItem(at:prepared.directory) }; importing = false; refresh() }
            do {
                let staging = runtime.repository.staging
                let package = try await Task.detached(priority:.userInitiated) { try ExtensionPackage.prepare(source:source,in:staging) }.value; prepared = package
                let alert = NSAlert(); alert.messageText = id == nil ? "安装“\(package.name)”？" : "更新为“\(package.name)”？"
                alert.informativeText = "版本 \(package.version)\n"+(id == nil ? "网站访问不会自动授权。" : "保留原有网站授权，新范围不会自动授权。")+"扩展会使用独立副本；更新后可能需要刷新网页。"
                let review = NSScrollView(frame:NSRect(x:0,y:0,width:460,height:180)); review.hasVerticalScroller = true; review.borderType = .bezelBorder
                let text = NSTextView(frame:review.bounds); text.isEditable = false; text.isSelectable = true; text.isHorizontallyResizable = false; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.font = BrowserStyle.body
                text.string = "API 权限：\(package.permissions.isEmpty ? "无" : package.permissions.joined(separator:", "))\n\n请求网站范围（安装后逐站授权）：\n\(package.hosts.isEmpty ? "未声明" : package.hosts.joined(separator:"\n"))"
                review.documentView = text; alert.accessoryView = review
                alert.addButton(withTitle:"取消"); alert.addButton(withTitle:id == nil ? "安装" : "更新")
                guard alert.runModal() == .alertSecondButtonReturn else { feedback.stringValue = "已取消导入"; return }
                try await runtime.install(package,replacing:id)
                feedback.stringValue = "扩展已启用。请按需要授权当前网站，再刷新页面。"
            } catch { feedback.stringValue = error.localizedDescription }
        }
    }
    @objc private func toggle() {
        guard let record = selected else { return }
        let enable = runtime.contexts[record.id]?.isLoaded != true
        Task { @MainActor in do { try await runtime.setEnabled(enable,id:record.id); feedback.stringValue = enable ? "已启用；刷新网页后检查效果。" : "已停用；网页中已发生的修改需刷新后撤销。" } catch { feedback.stringValue = error.localizedDescription } }
    }
    @objc private func removeSelected() {
        guard let record = selected else { return }
        let alert = NSAlert(); alert.messageText = "移除“\(record.name)”？"; alert.informativeText = "扩展程序副本移入废纸篓。已经修改的网页需要刷新。"
        let clear = NSButton(checkboxWithTitle:"同时删除扩展保存的数据（无法恢复）",target:nil,action:nil); clear.state = .off; alert.accessoryView = clear
        alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { @MainActor in do { try await runtime.remove(id:record.id,includingData:clear.state == .on); feedback.stringValue = clear.state == .on ? "扩展及保存的数据已移除。" : "程序已移除，保存的数据保留；更新导入可重新安装。" } catch { feedback.stringValue = error.localizedDescription } }
    }
    @objc private func openAction() { guard let id = selected?.id,let browser else { return }; browser.window?.makeKeyAndOrderFront(nil); runtime.performAction(id,browser:browser) }
    @objc private func openOptions() { guard let id = selected?.id else { return }; do { try runtime.showOptions(id) } catch { feedback.stringValue = error.localizedDescription } }
    @objc private func allowSite() {
        guard let id = selected?.id,let browser else { return }
        if runtime.grantCurrentSite(id,browser:browser) { feedback.stringValue = "已授权当前网站；刷新页面后检查扩展效果。" }
        else { feedback.stringValue = "未授权当前网站。" }
    }
    @objc private func revokeSite() {
        guard let record = selected,sites.indexOfSelectedItem >= 0 else { return }
        let keys = record.sites.keys.sorted(); guard keys.indices.contains(sites.indexOfSelectedItem) else { return }
        do { try runtime.setSite(keys[sites.indexOfSelectedItem],allowed:false,id:record.id); feedback.stringValue = "已撤销网站权限；刷新网页以清除已有修改。" }
        catch { feedback.stringValue = error.localizedDescription }
    }
    @objc private func reloadPage() {
        guard let browser,!browser.capturing else { return }
        browser.webView.reload(); browser.window?.makeKeyAndOrderFront(nil)
    }
}
