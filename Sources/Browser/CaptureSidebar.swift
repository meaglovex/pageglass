import AppKit

/// Sibling overlay, never an arranged view: opening it cannot resize the webpage.
final class CaptureSidebar:NSView {
    weak var browser:BrowserWindow?
    let detail:CaptureDetailView
    private var observer:NSObjectProtocol?
    init(browser:BrowserWindow) {
        self.browser = browser; detail = CaptureDetailView(browser:browser)
        super.init(frame:.zero); wantsLayer = true
        layer?.cornerRadius = 10; layer?.shadowOpacity = 0.15; layer?.shadowRadius = 12
        let title = NSTextField(labelWithString:"捕获结果"); title.font = .systemFont(ofSize:13,weight:.semibold)
        let close = ChromeButton(); browser.configure(close,"xmark","关闭捕获结果（Esc）",#selector(BrowserWindow.dismissCaptureSidebar))
        let space = NSView(); space.setContentHuggingPriority(.init(1),for:.horizontal)
        let header = NSStackView(views:[title,space,close]); header.spacing = 8; header.edgeInsets = NSEdgeInsets(top:6,left:18,bottom:6,right:8)
        for view in [header,detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:leadingAnchor),header.trailingAnchor.constraint(equalTo:trailingAnchor),header.topAnchor.constraint(equalTo:topAnchor),detail.topAnchor.constraint(equalTo:header.bottomAnchor),detail.leadingAnchor.constraint(equalTo:leadingAnchor),detail.trailingAnchor.constraint(equalTo:trailingAnchor),detail.bottomAnchor.constraint(equalTo:bottomAnchor)])
        setAccessibilityRole(.group); setAccessibilityLabel("捕获结果")
        observer = NotificationCenter.default.addObserver(forName:CaptureRetention.changed,object:nil,queue:.main) { [weak self] notification in
            guard let self,!isHidden,notification.object as? URL == self.browser?.captureRoot else { return }; detail.show(detail.directory)
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect:bounds,xRadius:10,yRadius:10).fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10).stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func cancelOperation(_ sender:Any?) { browser?.dismissCaptureSidebar() }
}

extension BrowserWindow {
    func showCaptureResult(_ result:CaptureResult) {
        if captureSidebar == nil {
            let panel = CaptureSidebar(browser:self); captureSidebar = panel
            panel.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(panel)
            NSLayoutConstraint.activate([panel.widthAnchor.constraint(equalToConstant:380),panel.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-8),panel.topAnchor.constraint(equalTo:content.topAnchor,constant:8),panel.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-8)])
        }
        captureSidebar?.isHidden = false; captureSidebar?.detail.show(result.directory)
        // Keep browsing focus. The user can move into the panel to copy or inspect.
    }
    @objc func dismissCaptureSidebar() { hideCaptureSidebar(restoreFocus:true) }
    func hideCaptureSidebar(restoreFocus:Bool = false) {
        guard let panel = captureSidebar,!panel.isHidden else { return }
        let ownedFocus = (window?.firstResponder as? NSView).map { $0.isDescendant(of:panel) } ?? false
        panel.isHidden = true
        if restoreFocus || ownedFocus { window?.makeFirstResponder(activeWebView) }
    }
}
