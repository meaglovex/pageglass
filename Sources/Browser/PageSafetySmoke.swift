import AppKit
import WebKit

/// Popups and page dialogs must not take over the browser. Uses only bundled and generated local pages.
@MainActor
enum PageSafetySmoke {
    static func run(_ browser:BrowserWindow,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ message:String) throws { guard condition else { throw CaptureService.Failure.message(message) }; checks.append(message) }
        func loaded(_ view:WKWebView) async throws {
            for _ in 0..<100 { try await Task.sleep(for:.milliseconds(50)); if !view.isLoading,view.url != nil { return } }
            throw CaptureService.Failure.message("page safety fixture timeout")
        }
        func until(_ condition:()->Bool) async throws { for _ in 0..<60 where !condition() { try await Task.sleep(for:.milliseconds(50)) } }
        let fixture = Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources")!
        let original = browser.webView
        browser.window?.makeKeyAndOrderFront(nil)

        // A page script without a user gesture cannot open tabs; an app-forced gesture still can.
        let popupPage = output.appendingPathComponent("popup-fixture.html")
        try "<!doctype html><title>popup fixture</title><script>window.opened = window.open('about:blank','_blank') !== null</script>".write(to:popupPage,atomically:true,encoding:.utf8)
        browser.openTab(popupPage); try await loaded(browser.webView)
        let count = browser.tabs.count, page = browser.webView
        try await Task.sleep(for:.milliseconds(300))
        let opened = try await page.evaluateJavaScript("window.opened") as? Bool
        try require(opened == false && browser.tabs.count == count && browser.webView === page,"scripted popup without a user gesture is blocked")
        _ = try await page.evaluateJavaScript("window.open('about:blank','_blank') !== null")
        try await until { browser.tabs.count == count+1 }
        try require(browser.tabs.count == count+1 && browser.webView !== page,"user-initiated popup still opens a tab")
        browser.closeTab()

        // Background tabs cannot show dialogs; the visible tab gets a window sheet, not an app-wide modal.
        browser.openTab(fixture); try await loaded(browser.webView)
        let background = browser.webView, foregroundIndex = browser.tabs.firstIndex { $0.webView === page }!
        browser.activate(foregroundIndex)
        _ = try await background.evaluateJavaScript("window.answer = 'pending'; setTimeout(() => { window.answer = confirm('background') }, 0)")
        try await Task.sleep(for:.milliseconds(300))
        let backgroundAnswer = try await background.evaluateJavaScript("window.answer") as? Bool
        try require(backgroundAnswer == false && browser.window?.attachedSheet == nil,"background tab dialog is dismissed without blocking the window")

        _ = try await page.evaluateJavaScript("window.answer = 'pending'; setTimeout(() => { window.answer = confirm('first') }, 0)")
        try await until { browser.window?.attachedSheet != nil }
        guard let first = browser.window?.attachedSheet,let tab = browser.tabs.first(where:{$0.webView === page}),let alert = tab.dialog else { throw CaptureService.Failure.message("active tab dialog did not appear as a sheet") }
        try require(!alert.showsSuppressionButton && NSApp.modalWindow == nil,"active tab dialog is a window sheet without app-wide modal state")
        browser.window?.endSheet(first,returnCode:.alertFirstButtonReturn)
        try await until { tab.dialog == nil }
        let accepted = try await page.evaluateJavaScript("window.answer") as? Bool
        try require(accepted == true,"accepting the sheet answers the page dialog")

        _ = try await page.evaluateJavaScript("setTimeout(() => { window.answer = confirm('second') }, 0)")
        try await until { tab.dialog != nil }
        guard let second = tab.dialog,let sheet = browser.window?.attachedSheet else { throw CaptureService.Failure.message("repeated dialog did not appear") }
        try require(second.showsSuppressionButton,"repeated dialogs offer to silence the page")
        second.suppressionButton?.state = .on
        browser.window?.endSheet(sheet,returnCode:.alertSecondButtonReturn)
        try await until { tab.dialog == nil }
        _ = try await page.evaluateJavaScript("window.answer = 'pending'; setTimeout(() => { window.answer = confirm('third') }, 0)")
        try await Task.sleep(for:.milliseconds(300))
        let silenced = try await page.evaluateJavaScript("window.answer") as? Bool
        try require(silenced == false && browser.window?.attachedSheet == nil,"silenced page cannot show more dialogs")

        // Closing a tab with an open dialog ends the sheet and answers WebKit.
        browser.activate(browser.tabs.firstIndex { $0.webView === background }!)
        _ = try await background.evaluateJavaScript("setTimeout(() => alert('closing'), 0)")
        try await until { browser.window?.attachedSheet != nil }
        try require(browser.window?.attachedSheet != nil,"dialog sheet shown before closing its tab")
        browser.closeTab()
        try await until { browser.window?.attachedSheet == nil }
        try require(browser.window?.attachedSheet == nil && browser.tabs.count == count,"closing a tab removes its dialog sheet")
        if let index = browser.tabs.firstIndex(where:{$0.webView === page}) { browser.close(at:index) }
        if let index = browser.tabs.firstIndex(where:{$0.webView === original}) { browser.activate(index) }
        return checks
    }

    /// HTTP Basic sign-in against the owned loopback fixture: wrong password, retry, success; cancel shows the server page.
    static func authentication(_ browser:BrowserWindow,base:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ message:String) throws { guard condition else { throw CaptureService.Failure.message(message) }; checks.append(message) }
        func until(_ condition:()->Bool) async throws { for _ in 0..<100 where !condition() { try await Task.sleep(for:.milliseconds(50)) } }
        func answer(user:String,password:String,accept:Bool) throws {
            guard let sheet = browser.window?.attachedSheet,let alert = browser.tabs[browser.activeIndex].dialog,let fields = alert.accessoryView?.subviews.compactMap({ $0 as? NSTextField }),fields.count == 2 else { throw CaptureService.Failure.message("sign-in sheet missing") }
            fields[0].stringValue = user; fields[1].stringValue = password
            browser.window?.endSheet(sheet,returnCode:accept ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        }
        browser.window?.makeKeyAndOrderFront(nil)
        browser.openTab(base.appendingPathComponent("basic-auth"))
        let view = browser.webView, tab = browser.tabs[browser.activeIndex]
        try await until { tab.dialog != nil }
        try require(tab.dialog?.messageText == "登录 127.0.0.1" && tab.dialog?.informativeText.contains("Pageglass QA") == true && tab.dialog?.informativeText.contains("未加密") == true,"HTTP sign-in sheet names the host, quotes the realm and warns about plain HTTP")
        try answer(user:"pageglass",password:"wrong",accept:true)
        try await until { tab.dialog != nil && tab.dialog?.informativeText.contains("不正确") == true }
        try require(tab.dialog?.informativeText.contains("不正确") == true,"wrong password asks again with a failure notice")
        try answer(user:"pageglass",password:"smoke-only",accept:true)
        try await until { view.title == "Authenticated fixture" }
        try require(view.title == "Authenticated fixture","correct credentials load the protected page")
        browser.closeTab()

        // The session now sends the saved credential to 127.0.0.1 without asking; use another origin for cancel.
        let other = URL(string:base.absoluteString.replacingOccurrences(of:"127.0.0.1",with:"localhost"))!.appendingPathComponent("basic-auth")
        browser.openTab(other)
        let cancelled = browser.webView, cancelTab = browser.tabs[browser.activeIndex]
        try await until { cancelTab.dialog != nil }
        let prefilled = cancelTab.dialog?.accessoryView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        try require(cancelTab.dialog?.messageText == "登录 localhost" && prefilled == ["",""],"another origin gets its own empty sign-in sheet")
        try answer(user:"",password:"",accept:false)
        try await until { cancelled.title == "Authentication required" }
        try require(cancelled.title == "Authentication required" && cancelTab.dialog == nil,"cancel shows the server's 401 page without prompting again")
        browser.closeTab()
        return checks
    }
}
