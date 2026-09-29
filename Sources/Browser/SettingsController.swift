import AppKit
import WebKit

final class SettingsController:NSWindowController {
    weak var browser:BrowserWindow?
    let engine = NSPopUpButton(), zoom = NSPopUpButton(), retention = NSPopUpButton()
    let retentionDays = [0,1,7,30]
    let captureSummary = NSTextField(labelWithString:"")
    let homepage = NSTextField()
    let restore = NSButton(checkboxWithTitle:"启动时恢复上次的标签页",target:nil,action:nil)
    let bookmarks = NSButton(checkboxWithTitle:"显示书签栏",target:nil,action:nil)
    let message = NSTextField(labelWithString:"")
    init(browser:BrowserWindow) {
        self.browser = browser
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:540),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "设置"; window.isReleasedWhenClosed = false
        super.init(window:window); window.center()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16; root.edgeInsets = NSEdgeInsets(top:28,left:28,bottom:28,right:28); window.contentView = root
        engine.addItems(withTitles:["Google","Bing","DuckDuckGo","百度"]); engine.selectItem(withTitle:browser.store.state.settings.searchEngine)
        zoom.addItems(withTitles:["80%","90%","100%","110%","125%","150%"]); zoom.selectItem(withTitle:"\(Int(browser.store.state.settings.defaultZoom*100))%")
        homepage.placeholderString = "留空使用新标签页"; homepage.stringValue = browser.store.state.settings.homepage
        restore.state = browser.store.state.settings.restoreSession ? .on : .off; bookmarks.state = browser.store.state.settings.showBookmarksBar ? .on : .off
        for (label,view) in [("搜索引擎",engine as NSView),("主页地址",homepage as NSView),("默认缩放",zoom as NSView)] {
            let title = NSTextField(labelWithString:label); title.widthAnchor.constraint(equalToConstant:85).isActive = true
            let row = NSStackView(views:[title,view]); row.spacing = 12; root.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-56).isActive = true
        }
        root.addArrangedSubview(restore); root.addArrangedSubview(bookmarks)
        retention.addItems(withTitles:["永不过期","1 天后","7 天后","30 天后"])
        retention.selectItem(at:retentionDays.firstIndex(of:browser.store.state.settings.captureRetentionDays ?? 0) ?? 0)
        let captureTitle = NSTextField(labelWithString:"捕获保留时间")
        let captureRow = NSStackView(views:[captureTitle,retention]); captureRow.spacing = 12;root.addArrangedSubview(captureRow)
        let explanation = NSTextField(wrappingLabelWithString:"到期捕获包移入废纸篓，原复制路径会失效。启动时及运行期间每小时检查；退出后下次启动再清理。已粘贴到其他应用的内容不受影响。")
        explanation.font = .systemFont(ofSize:12);explanation.textColor = .secondaryLabelColor
        root.addArrangedSubview(explanation);explanation.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-56).isActive = true
        let clearCaptures = NSButton(title:"清除全部捕获…",target:self,action:#selector(clearCapturedContent));clearCaptures.bezelStyle = .rounded
        captureSummary.font = .systemFont(ofSize:12);captureSummary.textColor = .secondaryLabelColor
        root.addArrangedSubview(NSStackView(views:[clearCaptures,captureSummary]));refreshCaptureSummary()
        let clear = NSButton(title:"清除网站数据…",target:self,action:#selector(clearData)); clear.bezelStyle = .rounded
        let apply = NSButton(title:"保存设置",target:self,action:#selector(save)); apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
        let row = NSStackView(views:[clear,apply]); row.spacing = 16; root.addArrangedSubview(row)
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize:12); root.addArrangedSubview(message)
    }
    required init?(coder:NSCoder) { fatalError() }
    func reloadValues() {
        guard let settings = browser?.store.state.settings else { return }
        engine.selectItem(withTitle:settings.searchEngine); homepage.stringValue = settings.homepage
        zoom.selectItem(withTitle:"\(Int(settings.defaultZoom*100))%")
        restore.state = settings.restoreSession ? .on : .off; bookmarks.state = settings.showBookmarksBar ? .on : .off
        message.stringValue = ""
        retention.selectItem(at:retentionDays.firstIndex(of:settings.captureRetentionDays ?? 0) ?? 0)
        refreshCaptureSummary()
    }
    @objc func save() {
        guard let browser else { return }
        var settings = browser.store.state.settings
        settings.searchEngine = engine.titleOfSelectedItem ?? "Google"; settings.homepage = homepage.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if !settings.homepage.isEmpty {
            guard let url = Navigation.url(for:settings.homepage),["http","https"].contains(url.scheme ?? "") else { message.stringValue = "主页地址无效"; return }; settings.homepage = url.absoluteString
        }
        settings.restoreSession = restore.state == .on; settings.showBookmarksBar = bookmarks.state == .on
        settings.defaultZoom = (Double((zoom.titleOfSelectedItem ?? "100%").dropLast()) ?? 100)/100
        settings.captureRetentionDays = retentionDays[max(0,retention.indexOfSelectedItem)]
        browser.store.updateSettings(settings); browser.store.flush()
        let cleaned = browser.cleanCaptures();refreshCaptureSummary()
        message.stringValue = browser.store.error ?? (cleaned.removed.isEmpty && cleaned.failures == 0 ? "已保存。默认缩放用于新打开的页面。" : cleaned.message)
    }
    func refreshCaptureSummary() {
        guard let browser else { return }
        do { captureSummary.stringValue = "本机保存 \(try CaptureRetention(root:browser.captureRoot).packages().count) 个捕获包" }
        catch { captureSummary.stringValue = "无法读取捕获目录" }
    }
    @objc func clearCapturedContent() {
        guard let browser else { return }
        let alert = NSAlert();alert.messageText = "清除全部捕获？"
        alert.informativeText = "捕获的截图、参考代码和交互记录将移入废纸篓，可从废纸篓恢复。原复制路径会失效；如果剪贴板仍是这些捕获，也会清空。其他应用中已经粘贴的内容不会被删除。"
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
