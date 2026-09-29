import AppKit
import WebKit

@MainActor
enum ExperienceSmoke {
    static func run(output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ value:Bool,_ message:String) throws { if !value { throw CaptureService.Failure.message(message) }; checks.append(message) }
        let fixture = Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources")!
        let store = BrowserStore(directory:output.appendingPathComponent("experience-store"))
        for count in [1,10] {
            let session = SavedWindow(tabs:(0..<count).map { SavedTab(url:fixture.absoluteString,title:"标签 \($0)") },active:0)
            let sample = BrowserWindow(store:store,session:session); sample.showWindow(nil)
            for width in [900.0,1280.0,1440.0] {
                sample.window?.setContentSize(NSSize(width:width,height:860)); sample.activate(count-1)
                sample.window?.contentView?.layoutSubtreeIfNeeded()
                let active = sample.tabButtons[sample.tabs[count-1].id]!
                try require(active.visibleRect.width >= active.bounds.width-1,"active tab is visible among \(count) tabs at width \(Int(width))")
            }
            sample.window?.close()
        }
        let session = SavedWindow(tabs:(0..<30).map { SavedTab(url:fixture.absoluteString,title:"标签 \($0)") },active:0)
        let browser = BrowserWindow(store:store,session:session); browser.showWindow(nil)
        defer { browser.window?.close() }
        for _ in 0..<100 { if !browser.webView.isLoading,browser.webView.title != nil { break }; try await Task.sleep(for:.milliseconds(50)) }
        for width in [900.0,1280.0,1440.0] {
            browser.window?.setContentSize(NSSize(width:width,height:860)); browser.activate(29)
            browser.window?.contentView?.layoutSubtreeIfNeeded()
            let active = browser.tabButtons[browser.tabs[29].id]!
            try require(active.visibleRect.width >= active.bounds.width-1,"active tab is visible among 30 tabs at width \(Int(width))")
        }
        let tab = browser.tabs[29], button = browser.tabButtons[tab.id]!
        if let root = browser.window?.contentView {
            let point = button.convert(NSPoint(x:45,y:15),to:root.superview)
            let hit = root.hitTest(point)
            try require(hit === button,"visible tab is reachable through the window hit-test hierarchy: hit=\(String(describing:hit)), row=\(browser.tabRow.frame), clip=\(browser.tabScroll.contentView.frame), scroll=\(browser.tabScroll.frame)")
        }
        browser.moveTab(tab.id,relativeTo:browser.tabs[0].id)
        if let root = browser.window?.contentView {
            let point = button.convert(NSPoint(x:45,y:15),to:root.superview)
            try require(root.hitTest(point) === button,"reordered tab remains reachable by pointer")
        }
        browser.moveTab(tab.id,relativeTo:browser.tabs[29].id)
        browser.moveTab(browser.tabs[29].id,relativeTo:tab.id)
        tab.title = "动态标题"; browser.renderTabs()
        try require(browser.tabButtons[tab.id] === button,"title updates preserve tab control identity")
        let list = TabListController(browser:browser); _ = list.view
        list.search.stringValue = "动态标题"; list.refresh()
        try require(list.matches.count == 1 && list.matches[0].id == tab.id,"tab search finds long-lived tab by title")
        for index in 0..<20 { store.toggleBookmark(title:"书签 \(index)",url:fixture.absoluteString+"#\(index)") }
        var settings = store.state.settings; settings.showBookmarksBar = true; store.updateSettings(settings)
        browser.window?.setContentSize(NSSize(width:900,height:860)); browser.renderBookmarks()
        let visible = browser.bookmarkRow.arrangedSubviews.compactMap { $0 as? BookmarkBarButton }.filter { $0.identifier != nil }.count
        try require(visible > 0 && visible+browser.overflowBookmarks.count == 20 && !browser.overflowBookmarks.isEmpty,"bookmark overflow retains all 20 records")
        let text = NSTextView(); text.setMarkedText("中",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        try require(!browser.control(browser.address,textView:text,doCommandBy:#selector(NSResponder.insertNewline(_:))),"IME composition confirmation does not navigate")
        for _ in 0..<100 { if !browser.webView.isLoading { break }; try await Task.sleep(for:.milliseconds(50)) }
        guard let argument = CommandLine.arguments.firstIndex(of:"--asset-test-url"),CommandLine.arguments.count > argument+1,let base = URL(string:CommandLine.arguments[argument+1]) else { throw CaptureService.Failure.message("experience checks require the local fixture server") }
        browser.load(base.appendingPathComponent("broken-navigation"))
        for _ in 0..<150 { if tab.failure != nil { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(tab.failure != nil && !browser.errorBar.isHidden,"failed navigation exposes persistent recovery controls: failure=\(tab.failure?.message ?? "none"), hidden=\(browser.errorBar.isHidden), loading=\(browser.webView.isLoading), url=\(browser.webView.url?.absoluteString ?? "none")")
        browser.activate(0); try require(browser.errorBar.isHidden,"failure does not affect another tab")
        browser.activate(29); try require(!browser.errorBar.isHidden,"returning to failed tab restores its error")
        browser.load(fixture)
        for _ in 0..<100 { if !browser.webView.isLoading { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(tab.failure == nil && browser.errorBar.isHidden,"successful navigation clears previous failure")
        for code in [102,204] {
            browser.webView(browser.webView,didFailProvisionalNavigation:nil,withError:NSError(domain:"WebKitErrorDomain",code:code))
            try require(tab.failure == nil && browser.errorBar.isHidden,"handled navigation \(code) does not show a page failure")
        }
        browser.webView(browser.webView,didFailProvisionalNavigation:nil,withError:NSError(domain:"WebKitErrorDomain",code:101))
        try require(tab.failure != nil && !browser.errorBar.isHidden,"unhandled WebKit navigation error remains visible")
        return checks
    }
}
