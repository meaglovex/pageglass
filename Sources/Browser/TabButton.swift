import AppKit

/// Tab controls occupy the titlebar; keep visible document controls hit-testable there.
final class TabClipView:NSClipView {
    override func hitTest(_ point:NSPoint)->NSView? {
        if let hit = super.hitTest(point) { return hit }
        let local = convert(point,from:superview)
        guard !isHidden,bounds.contains(local) else { return nil }
        return documentView?.hitTest(local)
    }
}

/// 原生标签使用自绘背景，文字、关闭按钮和无障碍仍是原生控件。
final class TabButton: NSView {
    let tabID: UUID
    var selected = false { didSet { needsDisplay = true } }
    var activate: (() -> Void)?
    var close: (() -> Void)?
    var drop: ((NSPoint)->Void)?
    var contextMenu: (() -> NSMenu)?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private let label = NSTextField(labelWithString:"")
    private let icon = NSImageView()
    let closeButton = NSButton()
    private var down: NSEvent?
    private var dragging = false

    init(tab:BrowserTab) {
        self.tabID = tab.id
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
    }
    func update(_ tab:BrowserTab,selected:Bool) {
        self.selected = selected
        label.stringValue = tab.title.isEmpty ? "新标签页" : tab.title
        icon.image = tab.favicon ?? NSImage(systemSymbolName:"globe",accessibilityDescription:nil)
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
        closeButton.setAccessibilityLabel("关闭 \(label.stringValue)")
        setAccessibilityLabel(label.stringValue)
        setAccessibilityValue(selected ? "当前标签页" : "")
        toolTip = "\(label.stringValue)\n\(tab.url?.absoluteString ?? "")"
    }
    required init?(coder:NSCoder) { fatalError() }
    override func hitTest(_ point:NSPoint)->NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Static title/icon views must not consume the tab's click or drag.
        return hit === closeButton || hit.isDescendant(of:closeButton) ? hit : self
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder()->Bool { needsDisplay = true; return true }
    override func resignFirstResponder()->Bool { needsDisplay = true; return true }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { activate?() } else { super.keyDown(with:event) }
    }
    override func draw(_ dirtyRect:NSRect) {
        let activeColor = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(calibratedWhite:0.20,alpha:1) : NSColor.white
        let fill = down != nil ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35) : selected ? activeColor : (hovering ? activeColor.withAlphaComponent(0.5) : .clear)
        fill.setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:9,yRadius:9).fill()
        if !selected { NSColor.separatorColor.setFill(); NSRect(x:bounds.width-1,y:9,width:0.5,height:bounds.height-18).fill() }
        if window?.firstResponder === self { NSGraphicsContext.saveGraphicsState(); NSFocusRingPlacement.only.set(); NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:7,yRadius:7).fill(); NSGraphicsContext.restoreGraphicsState() }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event:NSEvent) { down = event; needsDisplay = true; activate?() }
    override func mouseUp(with event:NSEvent) {
        let shouldDrop = dragging
        cancelOperation(nil)
        if shouldDrop { drop?(event.locationInWindow) }
    }
    override func cancelOperation(_ sender:Any?) {
        down = nil; dragging = false; alphaValue = 1; needsDisplay = true; NSCursor.arrow.set()
    }
    override func otherMouseDown(with event:NSEvent) { if event.buttonNumber == 2 { close?() } }
    override func accessibilityPerformPress()->Bool { activate?(); return true }
    @objc private func closePressed() { close?() }
    override func menu(for event:NSEvent)->NSMenu? { contextMenu?() }
    override func mouseDragged(with event:NSEvent) {
        guard let down, hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 else { return }
        dragging = true; alphaValue = 0.6; NSCursor.closedHand.set(); window?.makeFirstResponder(self)
        autoscroll(with:event)
    }
}

final class HeaderBackground: NSView {
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
}

final class ChromeStackView:NSStackView {
    var surfaceColor:NSColor = .controlBackgroundColor
    var cornerRadius:CGFloat = 0
    override func draw(_ dirtyRect:NSRect) { surfaceColor.setFill(); NSBezierPath(roundedRect:bounds,xRadius:cornerRadius,yRadius:cornerRadius).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
