import AppKit
import UniformTypeIdentifiers

final class CaptureEditorController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate,NSTextViewDelegate {
    static private(set) var openEditors:[String:CaptureEditorController] = [:]
    static func open(_ directory:URL,appearance:NSAppearance?) throws {
        let key = directory.resolvingSymlinksInPath().path
        let controller:CaptureEditorController
        if let existing = openEditors[key] { controller = existing }
        else { controller = try Self(directory:directory); openEditors[key] = controller }
        controller.window?.appearance = appearance; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    static func prepareToQuit()->Bool {
        for editor in Array(openEditors.values) where editor.dirty {
            editor.window?.makeKeyAndOrderFront(nil)
            if let window = editor.window,!editor.windowShouldClose(window) { return false }
        }
        return true
    }
    let directory:URL
    let canvas = CaptureAnnotationCanvas(), undo = UndoManager()
    private(set) var edits:CaptureEdits
    private var saved:CaptureEdits
    private let scroll = NSScrollView(), backdrop = AnnotationBackdrop(), tools = NSSegmentedControl(), zoom = NSPopUpButton(), color = NSPopUpButton()
    let name = NSTextField(), notes = NSTextView(), annotationText = NSTextField()
    private let status = NSTextField(wrappingLabelWithString:"")
    private let undoButton = NSButton(title:"撤销",target:nil,action:nil), redoButton = NSButton(title:"重做",target:nil,action:nil), deleteButton = NSButton(title:"删除",target:nil,action:nil)
    private var undoObservers:[NSObjectProtocol] = []
    var onClose:(()->Void)?
    var dirty:Bool { edits != saved || name.stringValue != saved.name || notes.string != saved.notes || (annotationText.isEnabled && annotationText.stringValue != edits.annotations.first(where:{$0.id == canvas.selected})?.text) }

    init(directory:URL) throws {
        self.directory = directory; edits = try CaptureEdits.load(in:directory); saved = edits
        let image = try CaptureAnnotationDrawing.image(in:directory)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:730),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "标注与备注"; window.minSize = NSSize(width:980,height:560); window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self; window.center()
        let root = NSView(); window.contentView = root
        tools.segmentCount = 5
        for (index,label) in ["选择","矩形","箭头","序号","文字"].enumerated() { tools.setLabel(label,forSegment:index); tools.setWidth(48,forSegment:index) }
        tools.selectedSegment = 0; tools.target = self; tools.action = #selector(changeTool); tools.setAccessibilityLabel("标注工具")
        zoom.addItems(withTitles:["适合窗口","50%","100%","200%"]); zoom.target = self; zoom.action = #selector(changeZoom); zoom.setAccessibilityLabel("标注画布缩放")
        color.addItems(withTitles:["红色","蓝色","棕色"]); color.target = self; color.action = #selector(changeColor); color.setAccessibilityLabel("标注颜色")
        for (button,action) in [(undoButton,#selector(undoEdit)),(redoButton,#selector(redoEdit)),(deleteButton,#selector(deleteMark))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1),for:.horizontal)
        let save = NSButton(title:"保存",target:self,action:#selector(saveDocument(_:))); save.bezelStyle = .rounded; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let toolbar = NSStackView(views:[tools,color,undoButton,redoButton,deleteButton,spacer,zoom,save]); toolbar.spacing = 8
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        canvas.image = image; canvas.marks = edits.annotations; canvas.setAccessibilityElement(true); canvas.setAccessibilityRole(.group); canvas.setAccessibilityLabel("截图标注画布，选择工具后拖动绘制；方向键移动选中标注，Delete 删除")
        backdrop.addSubview(canvas); scroll.documentView = backdrop
        name.stringValue = edits.name; name.placeholderString = "使用原页面标题"; name.delegate = self; name.setAccessibilityLabel("捕获显示名称")
        notes.string = edits.notes; notes.isRichText = false; notes.font = .systemFont(ofSize:13); notes.delegate = self; notes.allowsUndo = true; notes.isAutomaticQuoteSubstitutionEnabled = false; notes.setAccessibilityLabel("备注与修改要求")
        notes.textContainerInset = NSSize(width:6,height:6); notes.isHorizontallyResizable = false; notes.autoresizingMask = [.width]; notes.textContainer?.widthTracksTextView = true
        let noteScroll = NSScrollView(); noteScroll.hasVerticalScroller = true; noteScroll.borderType = .bezelBorder; noteScroll.documentView = notes; noteScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:140).isActive = true
        annotationText.placeholderString = "选中序号或文字后修改"; annotationText.delegate = self; annotationText.setAccessibilityLabel("选中标注的文字"); annotationText.isEnabled = false
        let export = NSButton(title:"导出标注图片…",target:self,action:#selector(exportImage)); export.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString:"原截图和网页参考保持不变。保存后可重新编辑；备注会随「复制给 Codex」一起提供。\n\n选择工具可拖动标注，方向键微调，Delete 删除。文字内容修改后按 Enter 应用。")
        hint.font = .systemFont(ofSize:12); hint.textColor = BrowserStyle.supportingText
        let side = NSStackView(views:[label("显示名称"),name,label("备注与修改要求"),noteScroll,label("选中标注文字"),annotationText,export,hint]); side.orientation = .vertical; side.alignment = .leading; side.spacing = 10
        for view in side.arrangedSubviews { view.widthAnchor.constraint(equalTo:side.widthAnchor).isActive = true }
        status.font = BrowserStyle.caption; status.textColor = BrowserStyle.supportingText; status.maximumNumberOfLines = 2
        for view in [toolbar,scroll,side,status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),toolbar.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),toolbar.topAnchor.constraint(equalTo:root.topAnchor,constant:10),
            scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor),scroll.topAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:10),scroll.trailingAnchor.constraint(equalTo:side.leadingAnchor,constant:-16),scroll.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-8),
            side.topAnchor.constraint(equalTo:scroll.topAnchor,constant:8),side.widthAnchor.constraint(equalToConstant:250),side.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),side.bottomAnchor.constraint(lessThanOrEqualTo:status.topAnchor,constant:-8),
            status.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),status.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-10),status.heightAnchor.constraint(greaterThanOrEqualToConstant:18)
        ])
        canvas.commit = { [weak self] marks,action in self?.setAnnotations(marks,action:action) }
        canvas.selectionChanged = { [weak self] in self?.updateSelection() }
        for event in [Notification.Name.NSUndoManagerDidUndoChange,.NSUndoManagerDidRedoChange,.NSUndoManagerDidCloseUndoGroup] {
            undoObservers.append(NotificationCenter.default.addObserver(forName:event,object:undo,queue:.main) { [weak self] _ in self?.refreshUndoState() })
        }
        root.layoutSubtreeIfNeeded(); changeZoom(); updateState()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { for observer in undoObservers { NotificationCenter.default.removeObserver(observer) } }
    private func label(_ value:String)->NSTextField { let label = NSTextField(labelWithString:value); label.font = .systemFont(ofSize:12,weight:.medium); return label }
    func setAnnotations(_ marks:[CaptureAnnotation],action:String) {
        guard marks != edits.annotations else { canvas.marks = marks; return }
        var proposed = edits; proposed.annotations = marks
        do { try proposed.validate() } catch { status.stringValue = error.localizedDescription; canvas.marks = edits.annotations; return }
        let previous = edits.annotations
        undo.registerUndo(withTarget:self) { target in target.setAnnotations(previous,action:action) }; undo.setActionName(action)
        edits.annotations = marks; canvas.marks = marks; updateState()
    }
    @objc func undoEdit() { undo.undo(); canvas.selected = nil; updateState() }
    @objc func redoEdit() { undo.redo(); canvas.selected = nil; updateState() }
    @objc private func deleteMark() { guard let selected = canvas.selected else { return }; setAnnotations(edits.annotations.filter{$0.id != selected},action:"删除标注"); canvas.selected = nil }
    @objc private func changeTool() { canvas.tool = tools.selectedSegment == 0 ? nil : CaptureAnnotation.Kind.allCases[tools.selectedSegment-1]; canvas.selected = nil; window?.makeFirstResponder(canvas) }
    @objc private func changeColor() {
        canvas.ink = CaptureAnnotation.Color.allCases[max(0,color.indexOfSelectedItem)]
        if let id = canvas.selected { setAnnotations(edits.annotations.map { var mark = $0; if mark.id == id { mark.color = canvas.ink }; return mark },action:"修改颜色") }
    }
    private func updateSelection() {
        let mark = edits.annotations.first{$0.id == canvas.selected}
        annotationText.isEnabled = mark?.kind == .text || mark?.kind == .number; annotationText.stringValue = annotationText.isEnabled ? mark?.text ?? "" : ""
        deleteButton.isEnabled = mark != nil
    }
    private func updateState() {
        refreshUndoState(); updateSelection()
    }
    private func refreshUndoState() {
        if let id = canvas.selected,!edits.annotations.contains(where:{$0.id == id}) { canvas.selected = nil }
        window?.isDocumentEdited = dirty; undoButton.isEnabled = undo.canUndo; redoButton.isEnabled = undo.canRedo
        status.stringValue = "\(edits.annotations.count) 个标注 · \(dirty ? "有未保存修改 · ⌘S 保存" : "已保存")"
    }
    func controlTextDidChange(_ notification:Notification) {
        window?.isDocumentEdited = dirty; status.stringValue = "有未保存修改 · ⌘S 保存"
    }
    func control(_ control:NSControl,textShouldEndEditing fieldEditor:NSText)->Bool {
        guard control === annotationText else { return true }
        let text = fieldEditor.string
        guard text.count <= 500 else { status.stringValue = "标注文字最多 500 字"; return false }
        if edits.annotations.first(where:{$0.id == canvas.selected})?.kind == .number,Int(text).map({(1...999).contains($0)}) != true { status.stringValue = "序号请输入 1–999"; return false }
        return true
    }
    func controlTextDidEndEditing(_ notification:Notification) {
        guard notification.object as? NSTextField === annotationText,let selected = canvas.selected else { return }
        let value = annotationText.stringValue
        if edits.annotations.first(where:{$0.id == selected})?.kind == .number,Int(value).map({(1...999).contains($0)}) != true { status.stringValue = "序号请输入 1–999"; return }
        setAnnotations(edits.annotations.map { var mark = $0; if mark.id == selected { mark.text = value }; return mark },action:"修改标注文字")
    }
    func textDidChange(_ notification:Notification) { window?.isDocumentEdited = dirty; status.stringValue = "有未保存修改 · ⌘S 保存" }
    func windowWillReturnUndoManager(_ window:NSWindow)->UndoManager? { undo }
    @discardableResult func saveEdits() throws->CaptureEdits {
        guard window?.makeFirstResponder(nil) != false else { throw CaptureEdits.Failure.message("请先修正标注文字，再保存") }
        edits.name = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); edits.notes = notes.string
        edits = try edits.save(in:directory,expectedRevision:saved.revision); saved = edits; name.stringValue = edits.name
        updateState(); NotificationCenter.default.post(name:CaptureEdits.changed,object:directory)
        return edits
    }
    @objc func saveDocument(_ sender:Any?) { do { try saveEdits() } catch { status.stringValue = error.localizedDescription } }
    @objc func closeTab() { window?.performClose(nil) }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard sender.makeFirstResponder(nil) else { return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "保存标注和备注？"; alert.informativeText = "未保存的编辑仍在此窗口中，原捕获文件没有改变。"
        alert.addButton(withTitle:"继续编辑"); alert.addButton(withTitle:"不保存"); alert.addButton(withTitle:"保存")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return true }
        if response == .alertThirdButtonReturn { do { try saveEdits(); return true } catch { status.stringValue = error.localizedDescription } }
        return false
    }
    func windowWillClose(_ notification:Notification) { Self.openEditors.removeValue(forKey:directory.resolvingSymlinksInPath().path); canvas.image = nil; scroll.documentView = nil; undo.removeAllActions(); onClose?() }
    func windowDidResize(_ notification:Notification) { layoutCanvas(reset:false) }
    @objc private func changeZoom() { layoutCanvas(reset:true) }
    private func layoutCanvas(reset:Bool) {
        guard let image = canvas.image else { return }
        let factors:[CGFloat] = [0,0.5,1,2], factor = factors[max(0,zoom.indexOfSelectedItem)]
        let scale = factor == 0 ? max(0.005,min(1,min(scroll.contentSize.width/image.size.width,scroll.contentSize.height/image.size.height))) : factor
        canvas.setFrameSize(NSSize(width:image.size.width*scale,height:image.size.height*scale))
        backdrop.setFrameSize(NSSize(width:max(scroll.contentSize.width,canvas.frame.width),height:max(scroll.contentSize.height,canvas.frame.height)))
        canvas.setFrameOrigin(NSPoint(x:(backdrop.frame.width-canvas.frame.width)/2,y:(backdrop.frame.height-canvas.frame.height)/2))
        if reset { backdrop.scroll(.zero) }
    }
    @objc private func exportImage() {
        guard let window,let image = canvas.image else { return }; window.makeFirstResponder(nil)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Pageglass-标注.png"
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self,result == .OK,let url = panel.url else { return }
            do {
                try CaptureCatalog.validate(directory)
                guard try CapturePortable.isOutsideCapture(url,source:directory) else { throw CaptureEdits.Failure.message("请导出到捕获包以外的目录，以保留原始文件") }
                try CaptureAnnotationDrawing.png(image:image,marks:edits.annotations).write(to:url,options:.atomic)
                status.stringValue = "已导出标注 PNG；可编辑内容请点击保存"
            } catch { status.stringValue = error.localizedDescription }
        }
    }
}

private final class AnnotationBackdrop:NSView { override var isFlipped:Bool { true } }
