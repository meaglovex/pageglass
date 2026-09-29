import AppKit

final class AppDelegate:NSObject,NSApplicationDelegate {
    var windows: [BrowserWindow] = []
    var isolatedStore:BrowserStore?
    var restoring = false
    var cleanupTimer: Timer?
    var browser:BrowserWindow? { windows.first }
    func applicationDidFinishLaunching(_ notification:Notification) {
        makeMenus(); let args = CommandLine.arguments
        if let index = args.firstIndex(of:"--smoke"),args.count > index+1 {
            let output = URL(fileURLWithPath:args[index+1]); let store = BrowserStore(directory:output.appendingPathComponent("browser-data"))
            isolatedStore = store
            let window = BrowserWindow(store:store); windows.append(window); window.showWindow(nil)
            NSApp.activate(ignoringOtherApps:true)
            Task { @MainActor in await SmokeTest.run(window,output:output) }; return
        }
        if let index = args.firstIndex(of:"--benchmark-plan"),args.count > index+1 {
            Task { @MainActor in await BenchmarkMode.run(path:args[index+1],delegate:self) }; return
        }
        restoring = true
        if BrowserStore.shared.state.settings.restoreSession {
            for session in BrowserStore.shared.state.windows where !session.tabs.isEmpty { createWindow(session:session) }
        }
        if windows.isEmpty { createWindow() }; restoring = false
        cleanExpiredCaptures()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval:3600,repeats:true) { [weak self] _ in self?.cleanExpiredCaptures() }
        NSApp.activate(ignoringOtherApps:true)
    }
    func cleanExpiredCaptures() {
        guard let browser else { return }
        let report = browser.cleanCaptures()
        if report.failures > 0 { browser.status.stringValue = report.message }
    }
    @objc func newWindow() { createWindow() }
    @objc func newPrivateWindow() { createWindow(privateBrowsing:true) }
    func createWindow(privateBrowsing:Bool = false,session:SavedWindow? = nil) {
        // Windows opened during explicit QA must keep using the isolated test profile.
        let window = BrowserWindow(privateBrowsing:privateBrowsing,store:isolatedStore ?? .shared,session:session)
        windows.append(window); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); saveSessions()
    }
    func closed(_ window:BrowserWindow) { windows.removeAll { $0 === window }; if !windows.isEmpty { saveSessions() } }
    func saveSessions() {
        guard !restoring,!CommandLine.arguments.contains("--smoke"),!BenchmarkMode.enabled else { return }
        let normal = windows.filter { !$0.privateBrowsing }
        if !normal.isEmpty { BrowserStore.shared.saveWindows(normal.map { $0.savedWindow() }) }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { if !hasVisibleWindows { createWindow() }; return true }
    func applicationWillTerminate(_ notification:Notification) { saveSessions(); if !BenchmarkMode.enabled && !CommandLine.arguments.contains("--smoke") { BrowserStore.shared.flush() } }

    private func makeMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title:String)->NSMenu { let item = NSMenuItem(title:title,action:nil,keyEquivalent:""); let sub = NSMenu(title:title); main.addItem(item); item.submenu = sub; return sub }
        func add(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String = "",_ modifiers:NSEvent.ModifierFlags = [.command],target:AnyObject? = nil) {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let app = menu("Pageglass")
        add(app,"关于Pageglass",#selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app,"设置…",#selector(BrowserWindow.showSettings),",")
        app.addItem(.separator()); add(app,"隐藏Pageglass",#selector(NSApplication.hide(_:)),"h"); add(app,"退出Pageglass",#selector(NSApplication.terminate(_:)),"q")
        let file = menu("文件")
        add(file,"新建标签页",#selector(BrowserWindow.newTab),"t")
        add(file,"新建窗口",#selector(newWindow),"n",target:self)
        add(file,"新建无痕窗口",#selector(newPrivateWindow),"n",[.command,.shift],target:self)
        add(file,"打开本地文件…",#selector(BrowserWindow.openFile),"o")
        add(file,"关闭标签页",#selector(BrowserWindow.closeTab),"w")
        add(file,"关闭窗口",#selector(NSWindow.performClose(_:)),"w",[.command,.shift])
        file.addItem(.separator()); add(file,"保存网页…",#selector(BrowserWindow.savePage),"s"); add(file,"打印…",#selector(BrowserWindow.printPage),"p")
        let edit = menu("编辑")
        add(edit,"撤销",Selector(("undo:")),"z"); add(edit,"重做",Selector(("redo:")),"z",[.command,.shift]); edit.addItem(.separator())
        add(edit,"剪切",#selector(NSText.cut(_:)),"x"); add(edit,"复制",#selector(NSText.copy(_:)),"c"); add(edit,"粘贴",#selector(NSText.paste(_:)),"v"); add(edit,"全选",#selector(NSText.selectAll(_:)),"a")
        add(edit,"在页面中查找…",#selector(BrowserWindow.findInPage),"f"); add(edit,"查找下一个",#selector(BrowserWindow.findNext),"g"); add(edit,"查找上一个",#selector(BrowserWindow.findPrevious),"g",[.command,.shift])
        let view = menu("显示")
        add(view,"快速操作…",#selector(BrowserWindow.showCommandPalette),"k")
        add(view,"书签栏",#selector(BrowserWindow.toggleBookmarksBar),"b",[.command,.shift]); add(view,"放大",#selector(BrowserWindow.zoomIn),"+"); add(view,"缩小",#selector(BrowserWindow.zoomOut),"-"); add(view,"实际大小",#selector(BrowserWindow.resetZoom),"0")
        add(view,"进入 / 退出全屏",#selector(NSWindow.toggleFullScreen(_:)),"f",[.command,.control])
        let developer = menu("开发")
        add(developer,"显示 / 关闭网页检查器",#selector(BrowserWindow.showDeveloperTools),String(UnicodeScalar(NSF12FunctionKey)!),[])
        add(developer,"显示 / 关闭网页检查器",#selector(BrowserWindow.showDeveloperTools),"i",[.command,.option])
        add(developer,"JavaScript 控制台",#selector(BrowserWindow.showJavaScriptConsole),"j",[.command,.option])
        developer.addItem(.separator())
        add(developer,"检查器兼容帮助…",#selector(BrowserWindow.showInspectorHelp))
        let history = menu("历史记录")
        add(history,"后退",#selector(BrowserWindow.goBack),"["); add(history,"前进",#selector(BrowserWindow.goForward),"]")
        add(history,"历史记录",#selector(BrowserWindow.showHistory),"y"); add(history,"重新打开关闭的标签页",#selector(BrowserWindow.reopenTab),"t",[.command,.shift])
        let bookmarks = menu("书签")
        add(bookmarks,"添加 / 移除书签",#selector(BrowserWindow.toggleBookmark),"d"); add(bookmarks,"书签管理",#selector(BrowserWindow.showBookmarks),"b",[.command,.option])
        let tabs = menu("标签页")
        add(tabs,"输入地址",#selector(BrowserWindow.focusAddress),"l"); add(tabs,"重新加载 / 停止",#selector(BrowserWindow.reload),"r")
        add(tabs,"下一个标签页",#selector(BrowserWindow.nextTab),"\t",[.control]); add(tabs,"上一个标签页",#selector(BrowserWindow.previousTab),"\t",[.control,.shift])
        for number in 1...9 { let item = NSMenuItem(title:number == 9 ? "最后一个标签页" : "标签页 \(number)",action:#selector(BrowserWindow.numberedTab(_:)),keyEquivalent:String(number)); item.tag = number; tabs.addItem(item) }
        add(tabs,"释放其他标签页…",#selector(BrowserWindow.suspendOthers))
        let capture = menu("捕获")
        add(capture,"开始 / 停止交互记录",#selector(BrowserWindow.toggleInteractionRecording),"i",[.command,.shift])
        add(capture,"捕获元素",#selector(BrowserWindow.selectElement),"c",[.command,.shift]); add(capture,"捕获全部",#selector(BrowserWindow.capturePage),"a",[.command,.shift])
        add(capture,"复制给 Codex",#selector(BrowserWindow.copyLatest)); add(capture,"复制截图",#selector(BrowserWindow.copyImage)); add(capture,"打开捕获文件夹",#selector(BrowserWindow.revealCapture))
        add(capture,"捕获历史…",#selector(BrowserWindow.showCaptureHistory))
        let windows = menu("窗口"); NSApp.windowsMenu = windows
        add(windows,"下载",#selector(BrowserWindow.showDownloads),"j"); add(windows,"最小化",#selector(NSWindow.performMiniaturize(_:)),"m")
    }
}
