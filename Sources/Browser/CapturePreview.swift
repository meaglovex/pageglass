import AppKit
import WebKit

final class CapturePreviewController:NSWindowController,NSWindowDelegate {
    init(browser:BrowserWindow,directory:URL) {
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:480,height:680),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "捕获结果"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:460,height:640)
        super.init(window:window)
        let detail = CaptureDetailView(browser:browser); window.contentView = detail
        window.delegate = self
        detail.show(directory); window.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func windowWillClose(_ notification:Notification) { (window?.contentView as? CaptureDetailView)?.reference?.close() }
}

final class CaptureDetailView:NSView {
    weak var browser:BrowserWindow?
    var directory:URL?
    var reference:CaptureReferenceController?
    private let image = NSImageView(), heading = NSTextField(wrappingLabelWithString:"选择一条捕获记录")
    private let summary = NSTextField(wrappingLabelWithString:""), notes = NSTextField(wrappingLabelWithString:""), feedback = NSTextField(wrappingLabelWithString:"")
    private var actions:[NSButton] = []
    private var generation = UUID()
    init(browser:BrowserWindow,showsHistory:Bool = true) {
        self.browser = browser
        super.init(frame:NSRect(x:0,y:0,width:480,height:680))
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:leadingAnchor,constant:18),root.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-18),root.topAnchor.constraint(equalTo:topAnchor,constant:18),root.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-18)])
        heading.font = .systemFont(ofSize:16,weight:.semibold); heading.maximumNumberOfLines = 2
        image.imageScaling = .scaleProportionallyDown; image.wantsLayer = true; image.layer?.cornerRadius = 8
        image.imageFrameStyle = .none; image.layer?.borderWidth = 1; image.layer?.borderColor = NSColor.separatorColor.cgColor
        image.heightAnchor.constraint(equalToConstant:180).isActive = true; image.setAccessibilityLabel("捕获截图预览")
        summary.font = .systemFont(ofSize:12); summary.textColor = .secondaryLabelColor; summary.maximumNumberOfLines = 5
        notes.font = .systemFont(ofSize:12); notes.isSelectable = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = notes
        notes.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([notes.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),notes.trailingAnchor.constraint(equalTo:scroll.contentView.trailingAnchor),notes.topAnchor.constraint(equalTo:scroll.contentView.topAnchor)])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:75).isActive = true
        let copy = action("重新复制给 Codex",#selector(copyPrompt)), picture = action("复制截图",#selector(copyImage))
        let inspect = action("查看参考",#selector(openReference)), reveal = action("在 Finder 中显示",#selector(reveal))
        let enlarge = action("查看大图",#selector(openImage)), history = NSButton(title:"捕获历史",target:browser,action:#selector(BrowserWindow.showCaptureHistory))
        history.bezelStyle = .rounded
        history.isHidden = !showsHistory
        feedback.font = .systemFont(ofSize:12); feedback.textColor = .secondaryLabelColor; feedback.maximumNumberOfLines = 2
        for view in [heading,image,summary,scroll,NSStackView(views:[copy,picture]),NSStackView(views:[inspect,reveal]),NSStackView(views:[enlarge,history]),feedback] {
            root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        }
        for button in actions { button.isEnabled = false }
    }
    required init?(coder:NSCoder) { fatalError() }
    private func action(_ title:String,_ selector:Selector)->NSButton {
        let button = NSButton(title:title,target:self,action:selector); button.bezelStyle = .rounded; actions.append(button); return button
    }
    func show(_ directory:URL?) {
        self.directory = directory; generation = UUID(); let token = generation
        image.image = nil; image.isHidden = directory == nil; notes.stringValue = ""; summary.stringValue = ""; feedback.stringValue = ""
        heading.stringValue = directory == nil ? "选择一条捕获记录" : "正在读取捕获…"
        for button in actions { button.isEnabled = false }
        guard let directory else { return }
        Task { @MainActor [weak self] in
            let record = await Task.detached(priority:.userInitiated) { CaptureCatalog.record(directory) }.value
            let thumbnail = await Task.detached(priority:.userInitiated) { CaptureCatalog.thumbnail(directory) }.value
            guard let self,generation == token else { return }
            heading.stringValue = "\(record.outcome) · \(record.title)"
            let steps = (record.metadata["interactionHistory"] as? [String:Any])?["steps"] as? Int ?? 0
            summary.stringValue = "\(record.scope) · \(ByteCountFormatter.string(fromByteCount:record.bytes,countStyle:.file)) · \(max(0,steps-1)) 次交互\n\(record.displaySource)\n\(record.expiration(days:browser?.store.state.settings.captureRetentionDays ?? 0))"
            summary.toolTip = record.source
            notes.stringValue = record.problem ?? record.warnings.map { "• "+$0 }.joined(separator:"\n")
            image.image = thumbnail
            feedback.stringValue = browser?.privateBrowsing == true ? "捕获已保存到本机，不会随无痕窗口关闭而删除。复制为本机文件引用。" : "复制给 Codex 的内容是本机文件引用；复制截图是独立操作。"
            for button in actions { button.isEnabled = record.problem == nil }
        }
    }
    private func perform(_ operation:(URL)throws->Void,message:String) {
        guard let directory else { return }
        do { try CaptureCatalog.validate(directory); try operation(directory); feedback.stringValue = message }
        catch { feedback.stringValue = "文件已清理、损坏或不可读，请刷新历史或重新捕获。"; for button in actions { button.isEnabled = false } }
    }
    @objc private func copyPrompt() { perform({ try CaptureCatalog.copyPrompt($0) },message:"已复制本机文件引用 · 在本机 Codex 粘贴") }
    @objc private func copyImage() { perform({ try CaptureCatalog.copyImage($0) },message:"已复制截图") }
    @objc private func reveal() { perform({ NSWorkspace.shared.activateFileViewerSelecting([$0]) },message:"") }
    @objc private func openImage() { perform({ NSWorkspace.shared.open(try CaptureCatalog.file("screenshot.png",in:$0)) },message:"") }
    @objc private func openReference() {
        perform({ directory in reference?.close(); reference = try CaptureReferenceController(directory:directory); reference?.showWindow(nil); reference?.window?.makeKeyAndOrderFront(nil) },message:"参考预览禁止运行网页脚本")
    }
}

final class CaptureReferenceController:NSWindowController,WKNavigationDelegate,NSWindowDelegate {
    let entry:URL
    init(directory:URL) throws {
        entry = try CaptureCatalog.file("reference.html",in:directory)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "捕获参考 · 脚本已禁用"; window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame:window.contentView!.bounds,configuration:config); view.navigationDelegate = self
        window.contentView = view; view.loadFileURL(entry,allowingReadAccessTo:directory); window.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func windowWillClose(_ notification:Notification) {
        (window?.contentView as? WKWebView)?.stopLoading(); (window?.contentView as? WKWebView)?.navigationDelegate = nil; window?.contentView = NSView()
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        decisionHandler(action.navigationType == .other && action.request.url == entry ? .allow : .cancel)
    }
}
