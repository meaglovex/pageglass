import AppKit
import WebKit

@MainActor
enum DeveloperToolsSmoke {
    static func run(_ browser:BrowserWindow) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ label:String) throws {
            guard condition else {
                let responder = browser.window?.firstResponder.map { String(describing:type(of:$0)) } ?? "nil"
                throw CaptureService.Failure.message("\(label) [appActive=\(NSApp.isActive), browserKey=\(browser.window?.isKeyWindow == true), keyIsBrowser=\(NSApp.keyWindow === browser.window), browserResponder=\(responder)]")
            };checks.append(label)
        }
        func wait(_ inspector:NSObject,visible:Bool) async throws {
            for _ in 0..<100 {
                if DeveloperTools.visible(inspector) == visible { return }
                try await Task.sleep(for:.milliseconds(50))
            }
            throw CaptureService.Failure.message("inspector visibility timeout: \(visible)")
        }
        let original = browser.webView
        guard let inspector = DeveloperTools.inspector(for:original) else { throw CaptureService.Failure.message("native inspector unavailable") }
        defer { DeveloperTools.close(original) }
        try require(DeveloperTools.open(original),"developer tools opens the current WebKit inspector")
        try await wait(inspector,visible:true)
        try require(DeveloperTools.call(inspector,"attach"),"visible inspector accepts explicit docking independent of its remembered layout")
        try await Task.sleep(for:.milliseconds(200));browser.window?.contentView?.layoutSubtreeIfNeeded()
        let host = browser.tabs[browser.activeIndex].container
        try require(original.frame.height < host.bounds.height-50 || original.frame.width < host.bounds.width-50,"docked inspector has visible space after Auto Layout")
        try require(DeveloperTools.open(original),"developer tools toggles closed")
        try await wait(inspector,visible:false)
        try require(original.window?.firstResponder === original,"closing developer tools through the toggle restores webpage keyboard focus")
        try require(DeveloperTools.open(original,console:true),"JavaScript console opens through native inspector")
        try await wait(inspector,visible:true)
        try require(DeveloperTools.closeCallbackAvailable,"inspector close callback matches the loaded WebKit delegate ABI")
        try require(DeveloperTools.call(inspector,"close"),"native inspector close path is available without the browser toggle")
        try await wait(inspector,visible:false)
        try await Task.sleep(for:.milliseconds(80))
        try require(original.window?.firstResponder === original,"native inspector close notification restores webpage keyboard focus")

        _ = DeveloperTools.open(original,console:true)
        try await wait(inspector,visible:true)
        browser.focusAddress();browser.address.stringValue = "inspector-close-draft"
        let addressEditor = browser.address.currentEditor()
        DeveloperTools.close(original)
        try await wait(inspector,visible:false)
        try await Task.sleep(for:.milliseconds(80))
        try require(addressEditor != nil && browser.window?.firstResponder === addressEditor && browser.address.stringValue == "inspector-close-draft","closing inspector preserves an active address editor and its draft")

        _ = DeveloperTools.open(original,console:true)
        try await wait(inspector,visible:true)
        DeveloperTools.close(original)
        browser.focusAddress()
        let newerEditor = browser.address.currentEditor()
        try await Task.sleep(for:.milliseconds(80))
        try require(newerEditor != nil && browser.window?.firstResponder === newerEditor,"deferred inspector close cannot steal a newer keyboard focus")

        _ = DeveloperTools.open(original,console:true)
        try await wait(inspector,visible:true)
        browser.showSettings()
        guard let settings = browser.settingsController,let settingsWindow = settings.window else { throw CaptureService.Failure.message("settings window missing during inspector focus test") }
        settingsWindow.makeKeyAndOrderFront(nil);settingsWindow.makeFirstResponder(settings.homepage)
        let settingsEditor = settings.homepage.currentEditor()
        func focusState()->String {
            "appActive=\(NSApp.isActive), settingsKey=\(settingsWindow.isKeyWindow), browserKey=\(browser.window?.isKeyWindow == true), editorExists=\(settingsEditor != nil), editorFocused=\(settingsEditor != nil && settingsWindow.firstResponder === settingsEditor), fieldAttached=\(settings.homepage.window === settingsWindow)"
        }
        let focusBeforeClose = focusState()
        DeveloperTools.close(original)
        try await wait(inspector,visible:false)
        try await Task.sleep(for:.milliseconds(80))
        if settingsEditor == nil || !settingsWindow.isKeyWindow || settingsWindow.firstResponder !== settingsEditor {
            print("INSPECTOR FOCUS before: \(focusBeforeClose); after: \(focusState())")
        }
        try require(settingsEditor != nil && settingsWindow.isKeyWindow && settingsWindow.firstResponder === settingsEditor,"closing an inspector does not steal focus from another window")
        settings.close();browser.window?.makeKeyAndOrderFront(nil)

        _ = DeveloperTools.open(original,console:true)
        try await wait(inspector,visible:true)
        let previousCount = browser.tabs.count
        browser.newTab()
        try require(host.window == nil,"switching tabs hides the entire previous inspector container")
        let another = browser.webView
        let newTabEditor = browser.address.currentEditor()
        DeveloperTools.close(original)
        try await wait(inspector,visible:false)
        try await Task.sleep(for:.milliseconds(80))
        try require(browser.activeWebView === another && newTabEditor != nil && browser.window?.firstResponder === newTabEditor,"closing a background tab inspector preserves the new tab address focus")
        guard let otherInspector = DeveloperTools.inspector(for:another) else { throw CaptureService.Failure.message("second inspector unavailable") }
        try require(otherInspector !== inspector,"each tab owns its own inspector")
        try require(DeveloperTools.open(another),"second tab inspector opens independently")
        try await wait(otherInspector,visible:true)
        let adjacent = browser.tabs[browser.activeIndex-1]
        browser.closeTab()
        try await wait(otherInspector,visible:false)
        try await Task.sleep(for:.milliseconds(80))
        try require(browser.tabs.count == previousCount && !browser.tabs.contains { $0.webView === another } && browser.tabs.contains { $0.webView === original },"closing inspected tab releases only its own page and inspector")
        try require(adjacent.webView != nil && browser.activeWebView === adjacent.webView && browser.window?.firstResponder === adjacent.webView,"closed tab inspector callback leaves the adjacent surviving page focused")
        DeveloperTools.close(original)
        try await wait(inspector,visible:false)
        checks += try await detachedCommands(browser)
        return checks
    }

    private static func detachedCommands(_ browser:BrowserWindow) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ label:String) throws {
            guard condition else { throw CaptureService.Failure.message(label) };checks.append(label)
        }
        func until(_ label:String,_ condition:()->Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for:.milliseconds(50))
            }
            throw CaptureService.Failure.message(label)
        }
        func detach(_ view:WKWebView,_ inspector:NSObject) async throws->NSWindow {
            guard DeveloperTools.open(view,console:true) else { throw CaptureService.Failure.message("cannot open inspector for detaching") }
            try await until("inspector did not become visible before detaching") { DeveloperTools.visible(inspector) == true }
            guard DeveloperTools.call(inspector,"detach") else { throw CaptureService.Failure.message("cannot detach inspector") }
            try await until("detached inspector did not become the key and main window") {
                DeveloperTools.front(inspector) == true && NSApp.keyWindow != nil && NSApp.keyWindow === NSApp.mainWindow && NSApp.keyWindow !== view.window
            }
            return NSApp.keyWindow!
        }
        func key(_ characters:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->Bool {
            guard let window = NSApp.keyWindow,
                  let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with:event) == true
        }
        guard let delegate = NSApp.delegate as? AppDelegate,delegate.windows.contains(where:{$0 === browser}) else { throw CaptureService.Failure.message("browser missing from application ownership") }
        let first = browser.webView
        guard let firstInspector = DeveloperTools.inspector(for:first) else { throw CaptureService.Failure.message("first detached inspector unavailable") }
        defer { DeveloperTools.close(first) }
        browser.window?.makeKeyAndOrderFront(nil)
        let firstWindow = try await detach(first,firstInspector)
        let toggle = #selector(BrowserWindow.showDeveloperTools)
        let item = NSMenuItem(title:"Inspector",action:toggle,keyEquivalent:"")
        try require(NSApp.target(forAction:toggle) as AnyObject? === delegate && delegate.validateMenuItem(item),"detached inspector commands resolve through the application responder chain")
        try require(key("j",38,[.command,.option]),"detached inspector accepts the Console menu shortcut")
        try require(DeveloperTools.visible(firstInspector) == true && NSApp.keyWindow === firstWindow,"Console shortcut keeps the corresponding detached inspector open")

        delegate.createWindow()
        guard let secondBrowser = delegate.windows.last,secondBrowser !== browser else { throw CaptureService.Failure.message("second browser window missing") }
        defer { if delegate.windows.contains(where:{$0 === secondBrowser}) { secondBrowser.close() } }
        let second = secondBrowser.webView
        guard let secondInspector = DeveloperTools.inspector(for:second) else { throw CaptureService.Failure.message("second detached inspector unavailable") }
        _ = try await detach(second,secondInspector)
        try require(delegate.frontInspectedPage()?.view === second && DeveloperTools.visible(firstInspector) == true,"front inspector ownership distinguishes two browser windows")
        try require(key("i",34,[.command,.option]),"detached inspector accepts the toggle menu shortcut")
        try await until("second inspector did not close") { DeveloperTools.visible(secondInspector) == false }
        try require(DeveloperTools.visible(firstInspector) == true,"toggling the front inspector leaves the other browser inspector open")

        secondBrowser.showSettings()
        guard let settings = secondBrowser.settingsController,let settingsWindow = settings.window else { throw CaptureService.Failure.message("settings missing during detached command test") }
        settingsWindow.makeKeyAndOrderFront(nil);settingsWindow.makeFirstResponder(settings.homepage)
        try require(delegate.frontInspectedPage() == nil && !delegate.validateMenuItem(item),"inspector fallback commands are disabled in unrelated settings windows")
        _ = NSApp.sendAction(toggle,to:delegate,from:nil)
        try require(DeveloperTools.visible(firstInspector) == true && settingsWindow.isKeyWindow,"unrelated-window fallback cannot close or focus another inspector")
        settings.close();secondBrowser.close()

        browser.window?.makeKeyAndOrderFront(nil)
        browser.newTab()
        let foreground = browser.webView
        defer { if browser.activeWebView === foreground { browser.closeTab() } }
        try require(first.window == nil && foreground !== first,"inspected page may be a background tab")
        firstWindow.makeKeyAndOrderFront(nil)
        try await until("background page inspector did not regain focus") { delegate.frontInspectedPage()?.view === first }
        try require(key(String(UnicodeScalar(NSF12FunctionKey)!),111,[.function]),"F12 menu shortcut resolves the front inspector of a background tab")
        try await until("F12 did not close background page inspector") { DeveloperTools.visible(firstInspector) == false }
        try require(browser.activeWebView === foreground && DeveloperTools.inspector(for:foreground).flatMap(DeveloperTools.visible) == false,"F12 does not inspect or switch the foreground browser tab")
        browser.window?.makeKeyAndOrderFront(nil)
        try require(NSApp.target(forAction:toggle) as AnyObject? === browser,"normal browser inspector commands retain their window responder")
        return checks
    }
}
