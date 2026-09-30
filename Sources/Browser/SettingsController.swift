import AppKit
import WebKit

final class SettingsController:NSWindowController {
    enum Page:String,CaseIterable { case general = "通用",appearance = "外观与工具栏",browsing = "浏览",capture = "捕获",extensions = "扩展",data = "数据" }
    weak var browser:BrowserWindow?
    let engine = NSPopUpButton(), zoom = NSPopUpButton(), retention = NSPopUpButton(), appearance = NSPopUpButton()
    let retentionDays = [0,1,7,30]
    let captureSummary = NSTextField(labelWithString:"")
    let homepage = NSTextField()
    let restore = NSButton(checkboxWithTitle:"启动时恢复上次的标签页",target:nil,action:nil)
    let bookmarks = NSButton(checkboxWithTitle:"显示书签栏",target:nil,action:nil)
    let autoCopy = NSButton(checkboxWithTitle:"捕获完成后自动复制给 Codex",target:nil,action:nil)
    let message = NSTextField(wrappingLabelWithString:"")
    private let heading = NSTextField(labelWithString:"")
    private let rows = NSStackView()
    private var navigation:[NSButton] = []
    private var toolButtons:[ToolbarTool:NSButton] = [:]
    private var selected = Page.general
    private var summaryGeneration = UUID()
    init(browser:BrowserWindow) {
        self.browser = browser
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:580),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "设置"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:720,height:540); window.appearance = browser.window?.appearance
        super.init(window:window); window.center()
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 6; sidebar.edgeInsets = NSEdgeInsets(top:24,left:12,bottom:20,right:12)
        for (index,page) in Page.allCases.enumerated() {
            let button = ChromeButton(title:page.rawValue,target:self,action:#selector(selectPage(_:))); button.tag = index; button.isBordered = false; button.setButtonType(.pushOnPushOff); button.alignment = .left; button.contentTintColor = .labelColor
            button.heightAnchor.constraint(equalToConstant:32).isActive = true; button.widthAnchor.constraint(equalToConstant:142).isActive = true
            sidebar.addArrangedSubview(button); navigation.append(button)
        }
        let sideSpace = NSView(); sideSpace.setContentHuggingPriority(.init(1),for:.vertical); sidebar.addArrangedSubview(sideSpace)
        let detail = NSStackView(); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 22; detail.edgeInsets = NSEdgeInsets(top:28,left:28,bottom:24,right:28)
        heading.font = BrowserStyle.title
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 16
        let space = NSView(); space.setContentHuggingPriority(.init(1),for:.vertical)
        message.font = BrowserStyle.caption; message.textColor = BrowserStyle.supportingText; message.maximumNumberOfLines = 3
        for view in [heading,rows,space,message] { detail.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:detail.widthAnchor,constant:-56).isActive = true }
        let root = NSStackView(views:[sidebar,detail]); root.spacing = 0; root.alignment = .top; window.contentView = root
        sidebar.widthAnchor.constraint(equalToConstant:166).isActive = true
        detail.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-166).isActive = true
        for view in [sidebar,detail] { view.heightAnchor.constraint(equalTo:root.heightAnchor).isActive = true }
        detail.setContentHuggingPriority(.defaultLow,for:.horizontal)
        engine.addItems(withTitles:["Google","Bing","DuckDuckGo","百度"])
        zoom.addItems(withTitles:["80%","90%","100%","110%","125%","150%"])
        appearance.addItems(withTitles:["跟随系统","浅色","深色"])
        retention.addItems(withTitles:["永不过期","1 天后","7 天后","30 天后"])
        homepage.placeholderString = "留空使用新标签页"; homepage.target = self; homepage.action = #selector(saveHomepage); homepage.setAccessibilityLabel("主页地址")
        for control in [engine,zoom,appearance,retention,restore,bookmarks,autoCopy] as [NSControl] { control.target = self; control.action = #selector(saveImmediately) }
        for tool in ToolbarTool.allCases {
            let button = NSButton(checkboxWithTitle:tool.title,target:self,action:#selector(saveImmediately)); toolButtons[tool] = button
        }
        reloadValues(); renderPage()
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func closeTab() { close() }
    @objc private func openExtensions() { browser?.showExtensions() }
    @objc private func selectPage(_ sender:NSButton) {
        guard Page.allCases.indices.contains(sender.tag) else { return }
        selected = Page.allCases[sender.tag]; renderPage()
    }
    private func add(_ view:NSView) { rows.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive = true }
    private func addAction(_ button:NSButton) {
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1),for:.horizontal)
        let row = NSStackView(views:[button,spacer]); row.spacing = 12; add(row)
    }
    private func text(_ value:String) {
        let label = NSTextField(wrappingLabelWithString:value); label.font = BrowserStyle.caption; label.textColor = BrowserStyle.supportingText; add(label)
    }
    private func row(_ label:String,_ view:NSView) {
        let title = NSTextField(labelWithString:label); title.widthAnchor.constraint(equalToConstant:90).isActive = true
        let row = NSStackView(views:[title,view]); row.spacing = 12; view.setContentHuggingPriority(.defaultLow,for:.horizontal); add(row)
    }
    private func button(_ title:String,_ action:Selector)->NSButton { let button = NSButton(title:title,target:self,action:action); button.bezelStyle = .rounded; return button }
    private func renderPage() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        heading.stringValue = selected.rawValue
        for (index,button) in navigation.enumerated() {
            button.state = Page.allCases[index] == selected ? .on : .off
            button.font = .systemFont(ofSize:13,weight:button.state == .on ? .semibold : .regular)
        }
        switch selected {
        case .general:
            row("搜索引擎",engine); add(restore)
            text("选择项与开关立即保存。主页留空时打开 Pageglass 新标签页。")
            row("主页地址",homepage); addAction(button("保存主页地址",#selector(saveHomepage)))
        case .appearance:
            row("主题",appearance); add(bookmarks)
            text("选择常驻工具。窄窗口会收起主页、设置与记录入口；所有操作仍可从菜单进入，记录中和下载中会保留对应入口。")
            for tool in ToolbarTool.allCases { if let button = toolButtons[tool] { add(button) } }
            addAction(button("恢复默认工具栏",#selector(resetToolbar)))
        case .browsing:
            row("默认缩放",zoom); text("用于新打开的页面。当前页面可用 ⌘+ / ⌘− 调整，⌘0 恢复。")
            text("普通窗口保留网站登录；无痕窗口不保存访问记录与会话。")
        case .capture:
            add(autoCopy); text("复制内容为本机捕获文件引用。关闭自动复制后，可以检查结果再手动复制。")
            row("保留时间",retention)
            text("到期捕获包移入废纸篓，原复制路径会失效。启动时及运行期间每小时检查；退出期间不清理。已粘贴到其他应用的内容不受影响。")
            captureSummary.font = BrowserStyle.caption; captureSummary.textColor = BrowserStyle.supportingText; add(captureSummary)
            addAction(button("清除全部捕获…",#selector(clearCapturedContent)))
        case .extensions:
            text("从本地目录或 ZIP 导入扩展，并按网站管理权限。扩展需要 macOS 15.4 或更高版本，不在无痕窗口运行。")
            addAction(button("管理扩展…",#selector(openExtensions)))
        case .data:
            text("清除网站 Cookie、缓存与本地存储后会退出网站登录。书签、捕获和下载文件保留。")
            addAction(button("清除网站数据…",#selector(clearData)))
        }
    }
    func reloadValues() {
        guard let settings = browser?.store.state.settings else { return }
        engine.selectItem(withTitle:settings.searchEngine); homepage.stringValue = settings.homepage
        zoom.selectItem(withTitle:"\(Int(settings.defaultZoom*100))%")
        appearance.selectItem(at:["system","light","dark"].firstIndex(of:settings.appearance ?? "system") ?? 0)
        restore.state = settings.restoreSession ? .on : .off; bookmarks.state = settings.showBookmarksBar ? .on : .off
        autoCopy.state = settings.autoCopyCapture == false ? .off : .on
        for (tool,button) in toolButtons { button.state = (settings.toolbarTools ?? ToolbarTool.defaults).contains(tool.rawValue) ? .on : .off }
        message.stringValue = ""
        retention.selectItem(at:retentionDays.firstIndex(of:settings.captureRetentionDays ?? 0) ?? 0)
        refreshCaptureSummary()
    }
    @objc private func saveImmediately() { persist(includeHomepage:false) }
    @objc private func saveHomepage() { persist(includeHomepage:true) }
    @objc func save() { persist(includeHomepage:true) }
    @objc private func resetToolbar() {
        for (tool,button) in toolButtons { button.state = ToolbarTool.defaults.contains(tool.rawValue) ? .on : .off }
        persist(includeHomepage:false)
    }
    private func persist(includeHomepage:Bool) {
        guard let browser else { return }
        var settings = browser.store.state.settings
        if includeHomepage {
            settings.homepage = homepage.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if !settings.homepage.isEmpty {
                // A homepage is an address, never a search query silently converted to a search URL.
                let value = settings.homepage.contains("://") ? settings.homepage : "https://"+settings.homepage
                guard let url = URL(string:value),["http","https"].contains(url.scheme ?? ""),url.host?.isEmpty == false,!settings.homepage.contains(where:{$0.isWhitespace}) else { message.stringValue = "主页地址无效，请输入完整网址。输入内容已保留。"; return }
                settings.homepage = url.absoluteString
            }
        }
        settings.searchEngine = engine.titleOfSelectedItem ?? "Google"
        settings.restoreSession = restore.state == .on; settings.showBookmarksBar = bookmarks.state == .on
        settings.defaultZoom = (Double((zoom.titleOfSelectedItem ?? "100%").dropLast()) ?? 100)/100
        settings.appearance = ["system","light","dark"][max(0,appearance.indexOfSelectedItem)]
        settings.toolbarTools = ToolbarTool.allCases.filter { toolButtons[$0]?.state == .on }.map(\.rawValue)
        settings.autoCopyCapture = autoCopy.state == .on
        settings.captureRetentionDays = retentionDays[max(0,retention.indexOfSelectedItem)]
        if settings.captureRetentionDays != browser.store.state.settings.captureRetentionDays,let days = settings.captureRetentionDays,days > 0 {
            let expired = (try? CaptureRetention(root:browser.captureRoot).packages().filter { Date().timeIntervalSince($0.date) >= Double(days)*86400 }.count) ?? 0
            if expired > 0 {
                let alert = NSAlert(); alert.messageText = "保存后将清理 \(expired) 个已到期捕获"
                alert.informativeText = "保留时间改为 \(days) 天。到期捕获将移入废纸篓，原复制路径会失效。"
                alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"保存并清理")
                guard alert.runModal() == .alertSecondButtonReturn else {
                    retention.selectItem(at:retentionDays.firstIndex(of:browser.store.state.settings.captureRetentionDays ?? 0) ?? 0); return
                }
            }
        }
        browser.store.updateSettings(settings); browser.store.flush()
        let cleaned = browser.cleanCaptures(); refreshCaptureSummary()
        if browser.store.error == nil,includeHomepage { homepage.stringValue = settings.homepage }
        let saved = !includeHomepage && homepage.stringValue != settings.homepage ? "已保存所选设置；主页地址尚未保存" : "已保存"
        message.stringValue = browser.store.error ?? (cleaned.removed.isEmpty && cleaned.failures == 0 ? saved : cleaned.message)
    }
    func refreshCaptureSummary() {
        guard let browser else { return }
        summaryGeneration = UUID(); let token = summaryGeneration,root = browser.captureRoot
        captureSummary.stringValue = "正在统计本机捕获…"
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority:.utility) { Result { () throws -> (Int,Int64) in
                let packages = try CaptureRetention(root:root).packages()
                return (packages.count,packages.reduce(0) { $0+CaptureCatalog.size(of:$1.url) })
            } }.value
            guard let self,summaryGeneration == token else { return }
            switch result {
            case .success(let value): captureSummary.stringValue = "\(value.0) 个捕获 · \(ByteCountFormatter.string(fromByteCount:value.1,countStyle:.file))"
            case .failure: captureSummary.stringValue = "无法读取捕获目录"
            }
        }
    }
    @objc func clearCapturedContent() {
        guard let browser else { return }
        let alert = NSAlert();alert.messageText = "清除全部捕获？"
        alert.informativeText = "\(captureSummary.stringValue)。全部捕获的截图、参考代码和交互记录将移入废纸篓，可从废纸篓恢复。原复制路径会失效；如果剪贴板仍是这些捕获，也会清空。其他应用中已经粘贴的内容不会被删除。"
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"移入废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        message.stringValue = browser.cleanCaptures(all:true).message;refreshCaptureSummary()
    }
    @objc func clearData() {
        guard let browser else { return }
        let alert = NSAlert(); alert.messageText = "清除网站数据？"; alert.informativeText = "将删除\(browser.privateBrowsing ? "当前无痕窗口" : "普通窗口")的网站 Cookie、缓存和本地存储，并退出网站登录。此操作不能撤销。书签和下载文件不受影响。"; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"清除网站数据")
        if alert.runModal() == .alertSecondButtonReturn {
            browser.websiteDataStore.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast) { [weak self] in self?.message.stringValue = "网站数据已清除" }
        }
    }
}
