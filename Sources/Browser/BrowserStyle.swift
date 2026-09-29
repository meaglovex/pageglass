import AppKit

/// Shared native chrome metrics. Webpage colors and layout remain owned by WebKit.
enum BrowserStyle {
    static let controlSize:CGFloat = 28
    static let iconSize:CGFloat = 15
    static let cornerRadius:CGFloat = 7
    static let body = NSFont.systemFont(ofSize:13)
    static let caption = NSFont.systemFont(ofSize:12)
    static let supportingText = NSColor(name:nil) { appearance in
        var resolved = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor.labelColor.usingColorSpace(.sRGB)!.withAlphaComponent(0.78) }
        return resolved
    }
    static let title = NSFont.systemFont(ofSize:20,weight:.semibold)
    static func appearance(_ value:String?)->NSAppearance? {
        switch value { case "light":return NSAppearance(named:.aqua);case "dark":return NSAppearance(named:.darkAqua);default:return nil }
    }
}

enum ToolbarTool:String,CaseIterable {
    case home,downloads,settings,recording
    var title:String { switch self { case .home:return "主页";case .downloads:return "下载";case .settings:return "设置";case .recording:return "记录交互" } }
    static let defaults:[String] = [ToolbarTool.downloads.rawValue]
}

final class ChromeButton:NSButton {
    private var tracking:NSTrackingArea?
    private var hovering = false
    // Borderless SF Symbol buttons otherwise inherit symbol-dependent alignment insets;
    // a nominal 28 pt button can become 32 pt tall and spill outside the tab strip.
    override var alignmentRectInsets:NSEdgeInsets { isBordered ? super.alignmentRectInsets : NSEdgeInsets() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:bounds,options:[.activeInKeyWindow,.mouseEnteredAndExited,.inVisibleRect],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        if isEnabled && (hovering || isHighlighted || state == .on) {
            (state == .on ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08)).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:BrowserStyle.cornerRadius,yRadius:BrowserStyle.cornerRadius).fill()
        }
        super.draw(dirtyRect)
    }
}

extension BrowserWindow {
    func applyAppearance() {
        let appearance = QAProfile.current?.appearance.map { NSAppearance(named:$0 == "Aqua" ? .aqua : .darkAqua) } ?? BrowserStyle.appearance(store.state.settings.appearance)
        for panel in [window,settingsController?.window,libraryController?.window,captureResultController?.window,captureLibraryController?.window] { panel?.appearance = appearance }
    }
    @objc func showCaptureMenu(_ sender:NSButton) {
        let menu = NSMenu()
        let actions:[(String,Selector)] = [("捕获元素",#selector(selectElement)),("捕获已加载整页",#selector(capturePage)),(interactionRecording?.isRecording == true ? "停止交互记录" : "记录交互",#selector(toggleInteractionRecording)),("捕获历史…",#selector(showCaptureHistory))]
        for (title,action) in actions {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; item.isEnabled = !capturing || action == #selector(showCaptureHistory); menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY),in:sender)
    }
    func syncDownloadIndicator() {
        let count = downloadRecords.values.filter { $0.state.hasPrefix("下载中") || $0.state == "等待保存" }.count
        downloadButton.image = NSImage(systemSymbolName:count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",accessibilityDescription:nil)
        downloadButton.contentTintColor = count > 0 ? .controlAccentColor : .labelColor
        let label = count > 0 ? "下载 · \(count) 项进行中（⌘J）" : "下载（⌘J）"
        downloadButton.toolTip = label; downloadButton.setAccessibilityLabel(label)
        updateToolbarLayout()
    }
}
