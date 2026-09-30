import AppKit
import Darwin

extension BrowserWindow {
    @objc func showCaptureHistory() {
        if captureLibraryController == nil { captureLibraryController = CaptureLibraryController(browser:self) }
        captureLibraryController?.showWindow(nil); captureLibraryController?.window?.makeKeyAndOrderFront(nil)
        captureLibraryController?.refresh()
    }
}

final class CaptureLibraryController:NSWindowController,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate,NSWindowDelegate {
    weak var browser:BrowserWindow?
    let search = NSSearchField(), table = NSTableView(), summary = NSTextField(labelWithString:"")
    let scope = NSPopUpButton(), period = NSPopUpButton()
    let emptyState = PanelEmptyState()
    private let listScroll = NSScrollView()
    private var readFailed = false
    let detail:CaptureDetailView
    let remove = NSButton(title:"移入废纸篓…",target:nil,action:nil)
    var records:[CaptureRecord] = [], filtered:[CaptureRecord] = []
    private let thumbnails = NSCache<NSURL,NSImage>()
    private var generation = UUID()
    private var observer:NSObjectProtocol?
    private var editObserver:NSObjectProtocol?
    private var watcher:DispatchSourceFileSystemObject?
    private var refreshWork:DispatchWorkItem?
    init(browser:BrowserWindow) {
        self.browser = browser; detail = CaptureDetailView(browser:browser,showsHistory:false)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "捕获历史"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:900,height:560)
        super.init(window:window); window.appearance = browser.window?.appearance; window.delegate = self; window.center(); thumbnails.countLimit = 48
        let root = NSView(); window.contentView = root
        let heading = NSTextField(labelWithString:"捕获历史"); heading.font = BrowserStyle.title
        search.placeholderString = "搜索名称、网址或备注"; search.delegate = self; search.setAccessibilityLabel("搜索捕获记录")
        scope.addItems(withTitles:["全部类型","元素","整页"]); scope.setAccessibilityLabel("按捕获类型筛选")
        period.addItems(withTitles:["全部日期","今天","最近 7 天","最近 30 天"]); period.setAccessibilityLabel("按捕获日期筛选")
        for menu in [scope,period] { menu.target = self; menu.action = #selector(filter) }
        let reload = NSButton(title:"刷新",target:self,action:#selector(refresh)); reload.bezelStyle = .rounded
        remove.target = self; remove.action = #selector(removeSelected); remove.bezelStyle = .rounded; remove.isEnabled = false
        let controls = NSStackView(views:[search,scope,period,reload,remove]); controls.spacing = 8
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        listScroll.hasVerticalScroller = true
        table.addTableColumn(NSTableColumn(identifier:.init("capture"))); table.headerView = nil; table.rowHeight = 72
        table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("捕获记录")
        listScroll.documentView = table; let list = emptyState.install(over:listScroll)
        split.addArrangedSubview(list); split.addArrangedSubview(detail)
        summary.font = BrowserStyle.caption; summary.textColor = BrowserStyle.supportingText; summary.lineBreakMode = .byTruncatingTail
        for view in [heading,controls,split,summary] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),heading.topAnchor.constraint(equalTo:root.topAnchor,constant:20),
            controls.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),controls.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),controls.topAnchor.constraint(equalTo:heading.bottomAnchor,constant:14),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant:180),
            split.topAnchor.constraint(equalTo:controls.bottomAnchor,constant:12),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:summary.topAnchor,constant:-10),
            summary.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),summary.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),summary.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-12),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant:320),detail.widthAnchor.constraint(greaterThanOrEqualToConstant:380)
        ])
        split.setPosition(460,ofDividerAt:0)
        observer = NotificationCenter.default.addObserver(forName:CaptureRetention.changed,object:nil,queue:.main) { [weak self] notification in
            guard let self,window.isVisible,let root = notification.object as? URL,root == self.browser?.captureRoot else { return }; self.refresh()
        }
        editObserver = NotificationCenter.default.addObserver(forName:CaptureEdits.changed,object:nil,queue:.main) { [weak self] _ in guard let self,window.isVisible else { return }; self.refresh() }
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func closeTab() { close() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let editObserver { NotificationCenter.default.removeObserver(editObserver) }; watcher?.cancel(); refreshWork?.cancel() }
    func windowDidBecomeKey(_ notification:Notification) { refresh() }
    func windowWillClose(_ notification:Notification) { watcher?.cancel(); watcher = nil; generation = UUID(); detail.closePreviews() }
    @objc func refresh() {
        guard let root = browser?.captureRoot else { return }
        generation = UUID(); let token = generation; summary.stringValue = "正在读取本机捕获…"
        if records.isEmpty { emptyState.show("正在读取捕获…",message:"正在读取本机记录和预览。",symbol:"clock"); emptyState.isHidden = false; listScroll.isHidden = true }
        if watcher == nil,(try? root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false {
            let fd = open(root.path,O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:.main)
                source.setCancelHandler { Darwin.close(fd) }
                source.setEventHandler { [weak self] in
                    if let events = self?.watcher?.data,!events.intersection([.rename,.delete]).isEmpty { self?.watcher?.cancel(); self?.watcher = nil }
                    self?.refreshWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in self?.refresh() }; self?.refreshWork = work
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
                }
                watcher = source; source.resume()
            }
        }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority:.userInitiated) { Result { try CaptureCatalog.scan(root) } }.value
            guard let self,generation == token else { return }
            switch result {
            case .success(let records): readFailed = false; self.records = records; filter()
            case .failure: readFailed = true; records = []; filter(); summary.stringValue = "无法读取捕获目录，请检查文件权限后刷新。"
            }
        }
    }
    @objc func filter() {
        let selected = Set(table.selectedRowIndexes.compactMap { filtered.indices.contains($0) ? filtered[$0].directory : nil })
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let mode:String? = scope.indexOfSelectedItem == 1 ? "element" : scope.indexOfSelectedItem == 2 ? "page" : nil
        let since:Date? = period.indexOfSelectedItem == 1 ? Calendar.current.startOfDay(for:Date()) : period.indexOfSelectedItem > 1 ? Date().addingTimeInterval(-Double(period.indexOfSelectedItem == 2 ? 7 : 30)*86400) : nil
        filtered = records.filter { CaptureRecordFilter.matches($0,query:query,mode:mode,since:since) }
        table.reloadData()
        let indexes = IndexSet(filtered.indices.filter { selected.contains(filtered[$0].directory) })
        table.selectRowIndexes(indexes,byExtendingSelection:false)
        if indexes.isEmpty {
            if filtered.isEmpty { detail.show(nil) }
            else { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
        }
        let size = ByteCountFormatter.string(fromByteCount:records.reduce(0) { $0+$1.bytes },countStyle:.file)
        let days = browser?.store.state.settings.captureRetentionDays ?? 0
        let expired = records.filter { days > 0 && Date().timeIntervalSince($0.date) >= Double(days)*86400 }.count
        summary.stringValue = "\(filtered.count) / \(records.count) 个捕获 · \(size) · \(days > 0 ? "保留 \(days) 天" : "永不过期")\(expired > 0 ? " · \(expired) 个已到期，待自动清理" : "")"
        remove.isEnabled = !table.selectedRowIndexes.isEmpty
        emptyState.isHidden = !filtered.isEmpty; listScroll.isHidden = filtered.isEmpty
        if filtered.isEmpty {
            if readFailed {
                emptyState.show("无法读取捕获记录",message:"请检查捕获目录的访问权限后重试，原文件不会被清除。",symbol:"exclamationmark.triangle",actionTitle:"重新读取",target:self,selector:#selector(refresh))
            } else if !query.isEmpty || scope.indexOfSelectedItem != 0 || period.indexOfSelectedItem != 0 {
                emptyState.show("没有匹配的捕获",message:"调整关键词、类型或日期，或清除筛选查看全部记录。",symbol:"magnifyingglass",actionTitle:"清除筛选",target:self,selector:#selector(clearFilters))
            } else {
                emptyState.show("还没有捕获记录",message:"回到网页点击「捕获」，选取元素或捕获已加载整页。",symbol:"viewfinder")
            }
        }
    }
    @objc func clearFilters() { search.stringValue = ""; scope.selectItem(at:0); period.selectItem(at:0); filter(); window?.makeFirstResponder(search) }
    func controlTextDidChange(_ notification:Notification) { filter() }
    func numberOfRows(in tableView:NSTableView)->Int { filtered.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let record = filtered[row], cell = NSTableCellView()
        cell.frame = NSRect(x:0,y:0,width:tableView.bounds.width,height:72)
        let picture = NSImageView(frame:NSRect(x:10,y:12,width:64,height:48)); picture.imageScaling = .scaleProportionallyDown; cell.addSubview(picture)
        let width = max(210,tableView.bounds.width-100)
        let lines = [record.title,URL(string:record.source)?.host ?? record.displaySource,"\(record.mode == "page" ? "整页" : "元素") · \(record.date.formatted(date:.abbreviated,time:.shortened)) · \(record.outcome)"]
        for (index,line) in lines.enumerated() {
            let label = NSTextField(labelWithString:line); label.frame = NSRect(x:84,y:49-CGFloat(index)*18,width:width,height:16); label.autoresizingMask = [.width]; label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize:index == 0 ? 12 : 11,weight:index == 0 ? .medium : .regular); label.textColor = index == 0 ? .labelColor : .secondaryLabelColor; cell.addSubview(label)
        }
        if let cached = thumbnails.object(forKey:record.directory as NSURL) { picture.image = cached }
        else {
            Task { @MainActor [weak self,weak picture] in
                let image = await Task.detached(priority:.utility) { CaptureCatalog.thumbnail(record.directory,pixels:128) }.value
                if let image { self?.thumbnails.setObject(image,forKey:record.directory as NSURL); picture?.image = image }
            }
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        remove.isEnabled = !table.selectedRowIndexes.isEmpty
        detail.show(filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].directory : nil)
    }
    @objc func removeSelected() {
        guard let browser else { return }
        let selected = table.selectedRowIndexes.compactMap { filtered.indices.contains($0) ? filtered[$0] : nil }
        guard !selected.isEmpty else { return }
        let size = ByteCountFormatter.string(fromByteCount:selected.reduce(0) { $0+$1.bytes },countStyle:.file)
        let alert = NSAlert(); alert.messageText = "将 \(selected.count) 个捕获移入废纸篓？"
        alert.informativeText = "共 \(size)，仅处理当前选中的捕获。原复制路径会失效，可从系统废纸篓恢复。其他应用中已粘贴的内容不受影响。"
        alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"移入废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let report = CaptureRetention(root:browser.captureRoot).remove(selected.map(\.directory))
        CaptureRetention.clearClipboard(for:report.removed)
        if let latest = browser.latest,report.removed.contains(latest.directory) { browser.latest = nil }
        thumbnails.removeAllObjects(); refresh(); browser.status.show(report.message,persistent:report.failures > 0)
        NotificationCenter.default.post(name:CaptureRetention.changed,object:browser.captureRoot)
    }
}
