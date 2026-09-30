import AppKit

extension BrowserWindow {
    /// Use the same actions and shortcuts as the menu bar. Native menus retain
    /// keyboard navigation, accessibility and system appearance automatically.
    func makeBrowserMenu() -> NSMenu {
        func menu(_ title:String = "") -> NSMenu {
            let result = NSMenu(title:title)
            result.font = .systemFont(ofSize:14)
            result.minimumWidth = 300
            result.autoenablesItems = false
            return result
        }
        @discardableResult
        func add(_ menu:NSMenu,_ title:String,_ icon:String,_ action:Selector?,_ key:String = "",_ modifiers:NSEvent.ModifierFlags = [.command],target:AnyObject? = nil,enabled:Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:key)
            item.target = target ?? self
            item.keyEquivalentModifierMask = modifiers
            item.image = NSImage(systemSymbolName:icon,accessibilityDescription:nil)
            item.image?.size = NSSize(width:18,height:18)
            if #available(macOS 27.0,*) { item.preferredImageVisibility = .visible }
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }
        let root = menu()
        let delegate = NSApp.delegate as? AppDelegate
        add(root,"新建标签页","plus.square",#selector(newTab),"t",enabled:!capturing)
        add(root,"新建窗口","macwindow.badge.plus",#selector(AppDelegate.newWindow),"n",target:delegate)
        add(root,"新建无痕窗口","eyeglasses",#selector(AppDelegate.newPrivateWindow),"n",[.command,.shift],target:delegate)
        root.addItem(.separator())

        let history = menu("历史记录")
        add(history,"显示全部历史记录","clock",#selector(showHistory),"y")
        add(history,"重新打开关闭的标签页","arrow.uturn.backward",#selector(reopenTab),"t",[.command,.shift],enabled:!capturing && !closedTabs.isEmpty)
        add(root,"历史记录","clock",nil).submenu = history
        add(root,"下载内容","arrow.down.to.line",#selector(showDownloads),"j")
        let bookmarks = menu("书签")
        add(bookmarks,"管理书签","bookmark",#selector(showBookmarks),"b",[.command,.option])
        add(bookmarks,"添加 / 移除当前书签","star",#selector(toggleBookmark),"d")
        bookmarks.addItem(.separator())
        add(bookmarks,"显示书签栏","sidebar.top",#selector(toggleBookmarksBar),"b",[.command,.shift]).state = store.state.settings.showBookmarksBar ? .on : .off
        add(root,"书签","star",nil).submenu = bookmarks
        add(root,"扩展程序","puzzlepiece.extension",#selector(showExtensions))
        root.addItem(.separator())

        let zoom = NSMenuItem(title:"缩放",action:nil,keyEquivalent:"")
        zoom.view = BrowserMenuZoomView(browser:self)
        root.addItem(zoom)
        root.addItem(.separator())
        add(root,"打印…","printer",#selector(printPage),"p",enabled:!capturing)
        add(root,"保存网页…","square.and.arrow.down",#selector(savePage),"s",enabled:!capturing)
        add(root,"在页面中查找…","doc.text.magnifyingglass",#selector(findInPage),"f")

        let capture = menu("捕获与交付")
        add(capture,"捕获元素","viewfinder",#selector(selectElement),"c",[.command,.shift],enabled:!capturing)
        add(capture,"捕获已加载整页","rectangle.dashed",#selector(capturePage),"a",[.command,.shift],enabled:!capturing)
        add(capture,interactionRecording?.isRecording == true ? "停止交互记录" : "开始交互记录","record.circle",#selector(toggleInteractionRecording),"i",[.command,.shift],enabled:!capturing)
        capture.addItem(.separator())
        add(capture,"捕获历史…","photo.on.rectangle",#selector(showCaptureHistory))
        add(capture,"复制给 Codex","doc.on.doc",#selector(copyLatest),enabled:latest != nil)
        add(capture,"复制截图","photo",#selector(copyImage),enabled:latest != nil)
        add(capture,"打开捕获文件夹","folder",#selector(revealCapture),enabled:latest != nil)
        add(root,"捕获与交付","viewfinder",nil).submenu = capture

        let tools = menu("更多工具")
        add(tools,"快速操作…","command",#selector(showCommandPalette),"k")
        add(tools,"主页","house",#selector(goHome),enabled:!capturing)
        tools.addItem(.separator())
        add(tools,"网页检查器","hammer",#selector(showDeveloperTools),"i",[.command,.option])
        add(tools,"JavaScript 控制台","terminal",#selector(showJavaScriptConsole),"j",[.command,.option])
        add(root,"更多工具","wrench.and.screwdriver",nil).submenu = tools
        root.addItem(.separator())
        add(root,"设置…","gearshape",#selector(showSettings),",")
        return root
    }
}

/// The percentage is also the reset button. Keep the menu open while zooming.
@MainActor
final class BrowserMenuZoomView:NSView {
    private weak var browser:BrowserWindow?
    private let percentage = NSButton()
    private let decrease = NSButton(), increase = NSButton()

    init(browser:BrowserWindow) {
        self.browser = browser
        super.init(frame:NSRect(x:0,y:0,width:300,height:46))
        let icon = NSImageView(frame:NSRect(x:20,y:14,width:18,height:18))
        icon.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil)
        icon.contentTintColor = .labelColor
        addSubview(icon)
        let title = NSTextField(labelWithString:"缩放")
        title.font = .systemFont(ofSize:14)
        title.frame = NSRect(x:47,y:14,width:48,height:19)
        addSubview(title)
        configure(decrease,title:"−",label:"缩小",x:112,width:30,action:#selector(zoomOut))
        configure(percentage,title:"",label:"恢复实际大小",x:145,width:58,action:#selector(resetZoom))
        configure(increase,title:"+",label:"放大",x:206,width:30,action:#selector(zoomIn))
        let fullScreen = NSButton()
        configure(fullScreen,title:"",label:"进入 / 退出全屏",x:253,width:30,action:#selector(toggleFullScreen))
        fullScreen.image = NSImage(systemSymbolName:"arrow.up.left.and.arrow.down.right",accessibilityDescription:nil)
        let divider = NSBox(frame:NSRect(x:244,y:10,width:1,height:26))
        divider.boxType = .separator
        addSubview(divider)
        refresh()
        viewDidChangeEffectiveAppearance()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func configure(_ button:NSButton,title:String,label:String,x:CGFloat,width:CGFloat,action:Selector) {
        button.frame = NSRect(x:x,y:8,width:width,height:30)
        button.title = title
        button.font = .monospacedDigitSystemFont(ofSize:14,weight:.regular)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.target = self; button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        addSubview(button)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for button in [decrease,percentage,increase] { button.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
        }
    }
    private func refresh() {
        guard let browser else { return }
        let zoom = browser.webView.pageZoom
        percentage.title = "\(Int((zoom*100).rounded()))%"
        percentage.setAccessibilityValue(percentage.title)
        percentage.isEnabled = !browser.capturing
        decrease.isEnabled = !browser.capturing && zoom > 0.5
        increase.isEnabled = !browser.capturing && zoom < 3
    }
    @objc private func zoomOut() { browser?.zoomOut(); refresh() }
    @objc private func zoomIn() { browser?.zoomIn(); refresh() }
    @objc private func resetZoom() { browser?.resetZoom(); refresh() }
    @objc private func toggleFullScreen() {
        enclosingMenuItem?.menu?.cancelTracking()
        browser?.window?.toggleFullScreen(nil)
    }
}
