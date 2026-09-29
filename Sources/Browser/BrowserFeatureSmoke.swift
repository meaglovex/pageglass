import AppKit
import WebKit

@MainActor
enum BrowserFeatureSmoke {
    static func run(_ browser:BrowserWindow) async throws->[String] {
        var checks: [String] = []
        func require(_ condition:Bool,_ message:String) throws { guard condition else { throw CaptureService.Failure.message(message) }; checks.append(message) }
        func loaded(_ view:WKWebView) async throws {
            for _ in 0..<100 { try await Task.sleep(for:.milliseconds(50)); if !view.isLoading,view.url != nil { return } }
            throw CaptureService.Failure.message("browser feature page timeout")
        }
        let fixture = Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources")!
        let original = browser.webView, count = browser.tabs.count
        browser.newTab(); try await loaded(browser.webView)
        try require(browser.tabs.count == count+1 && browser.webView !== original,"new tab has an independent live WebView")
        browser.closeTab()
        try require(browser.webView === original,"closing tab restores previous page without reloading")
        browser.reopenTab(); try await loaded(browser.webView)
        try require(browser.tabs.count == count+1,"closed tab reopens")
        browser.closeTab()
        browser.openTab(fixture); try await loaded(browser.webView)
        let moved = browser.tabs[browser.activeIndex].id
        browser.moveTab(moved,relativeTo:browser.tabs[0].id)
        try require(browser.tabs[0].id == moved && browser.activeIndex == 0,"reorder retains active tab identity")
        browser.moveTab(moved,relativeTo:browser.tabs.last!.id,after:true)
        try require(browser.tabs.last?.id == moved && browser.activeIndex == browser.tabs.count-1,"drag placement can move a tab to the end while preserving selection")
        browser.moveTab(moved,relativeTo:browser.tabs[0].id)
        try require(!browser.tabMenu(moved).items.contains { ($0.representedObject as? [String])?.last == "pin" },"tab menu has no pin action")
        for _ in 0..<100 { if browser.webView.title?.contains("捕获练习") == true { break }; try await Task.sleep(for:.milliseconds(50)) }
        browser.toggleBookmark(); browser.store.flush()
        try require(browser.store.bookmark(for:fixture.absoluteString) != nil,"bookmark current page")
        try require(browser.store.suggestions("捕获练习").contains { $0.url == fixture.absoluteString },"address suggestions include bookmark")
        let bookmark = browser.store.bookmark(for:fixture.absoluteString)!
        let menu = browser.bookmarkMenu(id:bookmark.id)
        try require(menu.items.contains { $0.title == "编辑书签…" && $0.representedObject as? String == bookmark.id.uuidString },"bookmark context menu targets the clicked bookmark for editing")
        try require(browser.bookmarkMenu(id:nil).items.contains { $0.title == "管理书签…" },"all bookmarks context menu opens management")
        for width in [110.0,230.0] {
            for title in ["短",String(repeating:"很长的标签标题",count:8)] {
                let tab = BrowserTab();tab.title = title
                let item = TabButton(tab:tab);item.frame = NSRect(x:0,y:0,width:width,height:30)
                browser.window?.contentView?.addSubview(item);browser.window?.contentView?.layoutSubtreeIfNeeded();item.layoutSubtreeIfNeeded()
                let rect = item.closeButton.alignmentRect(forFrame:item.closeButton.frame)
                try require(abs(rect.maxX-(width-10)) < 0.5,"tab close remains right aligned at width \(Int(width)) with \(title.count) title characters: \(rect.maxX), bounds \(item.bounds.width)")
                let titleHit = item.hitTest(item.convert(NSPoint(x:45,y:15),to:item.superview))
                let closeHit = item.hitTest(item.convert(NSPoint(x:rect.midX,y:rect.midY),to:item.superview))
                try require(titleHit === item,"tab title routes pointer events to drag target at width \(Int(width))")
                try require(closeHit === item.closeButton,"tab close keeps its own pointer target at width \(Int(width))")
                item.removeFromSuperview()
            }
        }
        browser.zoomIn(); try require(browser.webView.pageZoom > 1,"page zoom applies to engine"); browser.resetZoom()
        let found = await withCheckedContinuation { continuation in browser.webView.find("产品概览",configuration:WKFindConfiguration()) { continuation.resume(returning:$0.matchFound) } }
        try require(found,"find locates text in rendered page")
        _ = try await browser.webView.evaluateJavaScript("localStorage.setItem('pageglass-private-test','regular')")
        let privateWindow = BrowserWindow(privateBrowsing:true,store:browser.store); privateWindow.showWindow(nil); privateWindow.load(fixture)
        try await loaded(privateWindow.webView)
        let privateValue = try await privateWindow.webView.evaluateJavaScript("localStorage.getItem('pageglass-private-test')")
        try require(privateValue is NSNull && !privateWindow.websiteDataStore.isPersistent,"private window isolates web storage")
        _ = try await privateWindow.webView.evaluateJavaScript("localStorage.setItem('pageglass-private-test','private')")
        let regularValue = try await browser.webView.evaluateJavaScript("localStorage.getItem('pageglass-private-test')") as? String
        try require(regularValue == "regular","private storage cannot overwrite regular storage")
        privateWindow.window?.close()
        let session = browser.savedWindow()
        let restored = BrowserWindow(store:browser.store,session:session); restored.showWindow(nil)
        try require(restored.tabs.count == session.tabs.count && restored.activeIndex == session.active,"session preserves tabs and active position")
        try require(restored.tabs.enumerated().allSatisfy { $0.offset == restored.activeIndex || $0.element.webView == nil },"session loads only active tab")
        restored.window?.close()
        let last = BrowserWindow(store:browser.store); last.showWindow(nil)
        try await loaded(last.webView); last.closeTab()
        try require(last.activeWebView == nil && last.window?.isVisible == false,"closing last tab closes window and releases renderer")
        browser.window?.makeKeyAndOrderFront(nil)
        return checks
    }
}
