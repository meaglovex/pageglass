import AppKit
import WebKit
import UniformTypeIdentifiers

final class CaptureDetailView:NSView {
    weak var browser:BrowserWindow?
    var directory:URL?
    var reference:CaptureReferenceController?
    var imagePreview:CaptureImageController?
    private let image = NSImageView(), heading = NSTextField(wrappingLabelWithString:"选择一条捕获记录")
    private let summary = NSTextField(wrappingLabelWithString:""), notes = NSTextField(wrappingLabelWithString:""), feedback = NSTextField(wrappingLabelWithString:"")
    private var actions:[NSButton] = []
    var hasUsableActions:Bool { actions.contains(where:{$0.isEnabled}) }
    private var generation = UUID()
    private var editObserver:NSObjectProtocol?
    private let showsHistory:Bool
    private var exporting = false
    init(browser:BrowserWindow,showsHistory:Bool = true) {
        self.browser = browser; self.showsHistory = showsHistory
        super.init(frame:NSRect(x:0,y:0,width:480,height:680))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        let root = CaptureDetailStack(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top:18,left:18,bottom:18,right:18)
        root.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = root
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:leadingAnchor),scroll.trailingAnchor.constraint(equalTo:trailingAnchor),scroll.topAnchor.constraint(equalTo:topAnchor),scroll.bottomAnchor.constraint(equalTo:bottomAnchor),root.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),root.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),root.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor)])
        heading.font = .systemFont(ofSize:16,weight:.semibold); heading.maximumNumberOfLines = 2
        image.imageScaling = .scaleProportionallyDown; image.wantsLayer = true; image.layer?.cornerRadius = 8
        // Preview content must fit its pane, not resize the history divider when records change.
        for view in [image,heading,summary,notes,feedback] as [NSView] {
            view.setContentHuggingPriority(.init(1),for:.horizontal)
            view.setContentCompressionResistancePriority(.init(1),for:.horizontal)
        }
        image.imageFrameStyle = .none; image.layer?.borderWidth = 1; image.layer?.borderColor = NSColor.separatorColor.cgColor
        image.heightAnchor.constraint(equalToConstant:180).isActive = true; image.setAccessibilityLabel("捕获截图预览")
        summary.font = .systemFont(ofSize:12); summary.textColor = BrowserStyle.supportingText; summary.maximumNumberOfLines = 5
        notes.font = .systemFont(ofSize:12); notes.isSelectable = true
        let copy = action("复制给 Codex",#selector(copyPrompt)); copy.bezelColor = .controlAccentColor
        let enlarge = action("查看大图",#selector(openImage))
        let edit = action("标注与备注",#selector(openEditor))
        let more = action("更多操作",#selector(showActions(_:)))
        let secondary = NSStackView(views:[enlarge,edit,more]); secondary.spacing = 8
        feedback.font = BrowserStyle.caption; feedback.textColor = BrowserStyle.supportingText; feedback.maximumNumberOfLines = 3
        for view in [heading,image,summary,copy,secondary,feedback,notes] {
            root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-36).isActive = true
        }
        for button in actions { button.isEnabled = false }
        editObserver = NotificationCenter.default.addObserver(forName:CaptureEdits.changed,object:nil,queue:.main) { [weak self] notification in
            guard let self,let directory = self.directory,let changed = notification.object as? URL,CaptureRetention.samePackage(directory,changed) else { return }; self.show(directory)
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let editObserver { NotificationCenter.default.removeObserver(editObserver) } }
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
            if record.outcome == "部分捕获" {
                let labels = ["missing-assets":"部分图片或字体未保存", "element-clipped":"元素超出视口，只捕获可见部分", "page-changed":"捕获期间页面发生变化", "screenshot-limited":"截图达到大小上限"]
                let issues = record.metadata["qualityIssues"] as? [String] ?? []
                summary.stringValue = (issues.compactMap { labels[$0] }.prefix(2).joined(separator:"；"))+"\n"+summary.stringValue
            }
            summary.toolTip = record.source
            notes.stringValue = record.problem ?? ([record.editProblem,record.edits.notes.isEmpty ? nil : "备注：\n"+record.edits.notes,record.edits.annotations.isEmpty ? nil : "已保存 \(record.edits.annotations.count) 个标注",record.warnings.map { "• "+$0 }.joined(separator:"\n")].compactMap{$0}.joined(separator:"\n\n"))
            image.image = thumbnail
            feedback.stringValue = browser?.privateBrowsing == true ? "捕获已保存到本机，不会随无痕窗口关闭而删除。复制为本机文件引用。" : "复制给 Codex 的内容是本机文件引用；复制截图是独立操作。"
            for button in actions { button.isEnabled = record.problem == nil }
        }
    }
    private func perform(_ operation:(URL)throws->Void,message:String) {
        guard let directory else { return }
        do { try CaptureCatalog.validate(directory); try operation(directory); feedback.stringValue = message }
        catch { feedback.stringValue = error.localizedDescription; if (try? CaptureCatalog.validate(directory)) == nil { for button in actions { button.isEnabled = false } } }
    }
    @objc private func copyPrompt() { perform({ try CaptureCatalog.copyPrompt($0) },message:"已复制本机文件引用 · 在本机 Codex 粘贴") }
    @objc private func copyImage() { perform({ try CaptureCatalog.copyImage($0) },message:"已复制截图") }
    @objc private func reveal() { perform({ NSWorkspace.shared.activateFileViewerSelecting([$0]) },message:"") }
    @objc private func openImage() {
        perform({ directory in imagePreview?.close(); imagePreview = try CaptureImageController(directory:directory); imagePreview?.onClose = { [weak self] in self?.imagePreview = nil }; imagePreview?.window?.appearance = browser?.window?.appearance; imagePreview?.showWindow(nil); imagePreview?.window?.makeKeyAndOrderFront(nil) },message:"")
    }
    @objc private func openEditor() { perform({ try CaptureEditorController.open($0,appearance:browser?.window?.appearance) },message:"") }
    @objc private func showActions(_ sender:NSButton) {
        let menu = NSMenu()
        for (title,selector) in [("复制截图",#selector(copyImage)),("查看参考",#selector(openReference)),("导出捕获 ZIP…",#selector(exportZIP)),("导出捕获文件夹…",#selector(exportFolder)),("在 Finder 中显示",#selector(reveal))] {
            let item = NSMenuItem(title:title,action:selector,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        if showsHistory { let item = NSMenuItem(title:"捕获历史",action:#selector(BrowserWindow.showCaptureHistory),keyEquivalent:""); item.target = browser; menu.addItem(.separator()); menu.addItem(item) }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY),in:sender)
    }
    @objc private func exportZIP() { exportCapture(.zip) }
    @objc private func exportFolder() { exportCapture(.folder) }
    private func exportCapture(_ format:CapturePortable.Format) {
        guard let directory,let window,!exporting else { return }
        if CaptureEditorController.openEditors.values.contains(where:{CaptureRetention.samePackage($0.directory,directory) && $0.dirty}) { feedback.stringValue = "此捕获有未保存的编辑，请先在标注窗口保存后导出"; return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.title = format == .zip ? "导出捕获 ZIP" : "导出捕获文件夹"
        if format == .zip { panel.allowedContentTypes = [.zip] }
        panel.nameFieldStringValue = "Pageglass-\(directory.lastPathComponent)"+(format == .zip ? ".zip" : "")
        panel.message = "包含原截图、参考、结构、可读取资源及已保存编辑。不会上传；请选择新名称。"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .OK,let target = panel.url else { return }
            exporting = true; feedback.stringValue = "正在导出捕获包…"
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority:.userInitiated) { Result { try CapturePortable.export(directory,to:target,format:format) } }.value
                guard let self else { return }; exporting = false
                if self.directory == directory {
                    switch result { case .success:feedback.stringValue = "已导出到 \(target.lastPathComponent) · 可将完整包附加给接收工具"; case .failure(let error):feedback.stringValue = error.localizedDescription }
                }
            }
        }
    }
    func closePreviews() { reference?.close(); reference = nil; imagePreview?.close(); imagePreview = nil }

    @objc private func openReference() {
        perform({ directory in reference?.close(); reference = try CaptureReferenceController(directory:directory); reference?.window?.appearance = browser?.window?.appearance; reference?.showWindow(nil); reference?.window?.makeKeyAndOrderFront(nil) },message:"参考预览禁止运行网页脚本")
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
    @objc func closeTab() { close() }
    func windowWillClose(_ notification:Notification) {
        (window?.contentView as? WKWebView)?.stopLoading(); (window?.contentView as? WKWebView)?.navigationDelegate = nil; window?.contentView = NSView()
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        decisionHandler(action.navigationType == .other && action.request.url == entry ? .allow : .cancel)
    }
}

private final class CaptureDetailStack:NSStackView { override var isFlipped:Bool { true } }
