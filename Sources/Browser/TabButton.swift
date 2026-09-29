import AppKit

/// 原生标签使用自绘背景，文字、关闭按钮和无障碍仍是原生控件。
final class TabButton: NSView, NSDraggingSource {
    static let pasteType = NSPasteboard.PasteboardType("dev.pageglass.tab")
    let tabID: UUID
    let ownerID: UUID
    var selected = false { didSet { needsDisplay = true } }
    var activate: (() -> Void)?
    var close: (() -> Void)?
    var reorder: ((UUID)->Void)?
    var contextMenu: (() -> NSMenu)?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private let label = NSTextField(labelWithString:"")
    private let icon = NSImageView()
    let closeButton = NSButton()
    private var down: NSEvent?

    init(tab:BrowserTab,ownerID:UUID) {
        self.tabID = tab.id; self.ownerID = ownerID
        super.init(frame:.zero)
        icon.image = tab.favicon ?? NSImage(systemSymbolName:"globe",accessibilityDescription:nil)
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil; icon.imageScaling = .scaleProportionallyDown
        label.stringValue = tab.title.isEmpty ? "新标签页" : tab.title
        label.font = .systemFont(ofSize:12); label.lineBreakMode = .byTruncatingTail
        closeButton.image = NSImage(systemSymbolName:"xmark",accessibilityDescription:"关闭标签页")
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("关闭 \(label.stringValue)")
        for view in [icon,label,closeButton] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(icon)
        NSLayoutConstraint.activate([icon.centerYAnchor.constraint(equalTo:centerYAnchor),icon.widthAnchor.constraint(equalToConstant:14),icon.heightAnchor.constraint(equalToConstant:14)])
        addSubview(label);addSubview(closeButton)
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),
            label.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:7),
            label.trailingAnchor.constraint(equalTo:closeButton.leadingAnchor,constant:-7),
            label.centerYAnchor.constraint(equalTo:centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            closeButton.centerYAnchor.constraint(equalTo:centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant:16),closeButton.heightAnchor.constraint(equalToConstant:16)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label.stringValue)
        toolTip = tab.url?.absoluteString ?? label.stringValue
        registerForDraggedTypes([Self.pasteType])
    }
    required init?(coder:NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect:NSRect) {
        let activeColor = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(calibratedWhite:0.20,alpha:1) : NSColor.white
        let fill = selected ? activeColor : (hovering ? activeColor.withAlphaComponent(0.5) : .clear)
        fill.setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:9,yRadius:9).fill()
        if !selected { NSColor.separatorColor.setFill(); NSRect(x:bounds.width-1,y:9,width:0.5,height:bounds.height-18).fill() }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event:NSEvent) { down = event }
    override func mouseUp(with event:NSEvent) { if down != nil { down = nil; activate?() } }
    override func otherMouseDown(with event:NSEvent) { if event.buttonNumber == 2 { close?() } }
    override func accessibilityPerformPress()->Bool { activate?(); return true }
    @objc private func closePressed() { close?() }
    override func menu(for event:NSEvent)->NSMenu? { contextMenu?() }
    override func mouseDragged(with event:NSEvent) {
        guard let down, hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 else { return }
        self.down = nil
        let item = NSPasteboardItem(); item.setString("\(ownerID.uuidString):\(tabID.uuidString)",forType:Self.pasteType)
        let drag = NSDraggingItem(pasteboardWriter:item)
        let image = NSImage(size:bounds.size); image.lockFocus(); NSColor.controlAccentColor.withAlphaComponent(0.2).setFill(); NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill(); image.unlockFocus()
        drag.setDraggingFrame(bounds,contents:image); beginDraggingSession(with:[drag],event:event,source:self)
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .move }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        guard sender.draggingPasteboard.string(forType:Self.pasteType)?.hasPrefix(ownerID.uuidString+":") == true else { return [] }; return .move
    }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard let raw = sender.draggingPasteboard.string(forType:Self.pasteType),raw.hasPrefix(ownerID.uuidString+":"),let uuid = UUID(uuidString:String(raw.split(separator:":").last ?? "")) else { return false }
        reorder?(uuid); return true
    }
}

final class HeaderBackground: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
}
