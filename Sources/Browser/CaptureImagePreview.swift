import AppKit

final class CaptureImageController:NSWindowController,NSWindowDelegate {
    private let scroll = NSScrollView(), imageView = NSImageView(), zoom = NSPopUpButton()
    private let canvas = CaptureImageCanvas()
    var onClose:(()->Void)?
    private let picture:NSImage
    private let factors:[CGFloat] = [0,1,0.5,2]
    init(directory:URL) throws {
        guard let image = NSImage(contentsOf:try CaptureCatalog.file("screenshot.png",in:directory)),image.size.width > 0,image.size.height > 0 else { throw CaptureService.Failure.message("截图不可读") }
        picture = image
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "捕获截图"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:460,height:360)
        super.init(window:window); window.delegate = self
        let root = NSView(); window.contentView = root
        zoom.addItems(withTitles:["适合窗口","100%","50%","200%"]); zoom.target = self; zoom.action = #selector(changeZoom); zoom.setAccessibilityLabel("截图缩放")
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        imageView.image = image; imageView.imageScaling = .scaleAxesIndependently; imageView.setAccessibilityLabel("捕获截图，使用缩放菜单检查细节"); canvas.addSubview(imageView); scroll.documentView = canvas
        for view in [zoom,scroll] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([zoom.topAnchor.constraint(equalTo:root.topAnchor,constant:8),zoom.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),scroll.topAnchor.constraint(equalTo:zoom.bottomAnchor,constant:8),scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        root.layoutSubtreeIfNeeded(); window.center(); changeZoom()
    }
    required init?(coder:NSCoder) { fatalError() }
    func windowDidResize(_ notification:Notification) { if zoom.indexOfSelectedItem == 0 { changeZoom() } }
    @objc func closeTab() { close() }
    func windowWillClose(_ notification:Notification) { scroll.documentView = nil; imageView.image = nil; onClose?() }
    @objc private func changeZoom() {
        let factor = factors[max(0,zoom.indexOfSelectedItem)]
        let scale = factor == 0 ? min(1,min(scroll.contentSize.width/picture.size.width,scroll.contentSize.height/picture.size.height)) : factor
        imageView.setFrameSize(NSSize(width:max(1,picture.size.width*scale),height:max(1,picture.size.height*scale)))
        canvas.setFrameSize(NSSize(width:max(scroll.contentSize.width,imageView.frame.width),height:max(scroll.contentSize.height,imageView.frame.height)))
        imageView.setFrameOrigin(NSPoint(x:(canvas.frame.width-imageView.frame.width)/2,y:(canvas.frame.height-imageView.frame.height)/2))
        canvas.scroll(.zero)
    }
}

private final class CaptureImageCanvas:NSView { override var isFlipped:Bool { true } }
