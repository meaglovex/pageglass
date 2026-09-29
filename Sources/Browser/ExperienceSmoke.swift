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
        // Let the pending window resize finish: resizing intentionally closes popovers.
        browser.window?.makeKeyAndOrderFront(nil); browser.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(100))
        guard let overflowButton = browser.bookmarkRow.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where:{$0.action == #selector(BrowserWindow.showBookmarkOverflow(_:))}) else { throw CaptureService.Failure.message("bookmark overflow button missing") }
        browser.showBookmarkOverflow(overflowButton)
        guard let overflow = browser.bookmarkPopover?.contentViewController as? BookmarkListController else { throw CaptureService.Failure.message("bookmark overflow list missing") }
        let overflowTable = overflow.table
        for _ in 0..<20 { if overflowTable.window?.firstResponder === overflowTable { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(overflowTable.visibleRect.contains(overflowTable.rect(ofRow:0)) && overflowTable.selectedRow == 0,"bookmark overflow opens at its first record: visible=\(overflowTable.visibleRect), row=\(overflowTable.rect(ofRow:0)), selected=\(overflowTable.selectedRow)")
        try require(overflowTable.window?.firstResponder === overflowTable,"bookmark overflow receives keyboard focus: shown=\(browser.bookmarkPopover?.isShown ?? false), responder=\(String(describing:overflowTable.window?.firstResponder))")
        func key(_ code:UInt16,in table:NSTableView? = nil)->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:(table ?? overflowTable).window?.windowNumber ?? 0,context:nil,characters:code == 125 ? "\u{F701}" : "\r",charactersIgnoringModifiers:code == 125 ? "\u{F701}" : "\r",isARepeat:false,keyCode:code)!
        }
        overflowTable.keyDown(with:key(125))
        try require(overflowTable.selectedRow == 1 && browser.bookmarkPopover?.isShown == true,"bookmark arrow key selects without navigating")
        let clickedRow = 2, rect = overflowTable.rect(ofRow:clickedRow)
        let point = overflowTable.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)
        let event = NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:overflowTable.window?.windowNumber ?? 0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        let contextMenu = overflowTable.menu(for:event)
        try require(overflowTable.selectedRow == clickedRow && contextMenu?.items.contains(where:{$0.title == "编辑书签…" && $0.representedObject as? String == overflow.records[clickedRow].id.uuidString}) == true,"overflow context menu edits the clicked row instead of the earlier keyboard selection")
        func waitClosed() async throws {
            for _ in 0..<20 { if browser.bookmarkPopover?.isShown != true { return }; try await Task.sleep(for:.milliseconds(50)) }
        }
        overflowTable.keyDown(with:key(36))
        try await waitClosed()
        for _ in 0..<40 { if browser.webView.url?.absoluteString == overflow.records[clickedRow].url { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(browser.bookmarkPopover?.isShown == false && browser.webView.url?.absoluteString == overflow.records[clickedRow].url,"Return opens the selected overflow bookmark and closes the list")
        browser.showBookmarkOverflow(overflowButton)
        (browser.bookmarkPopover?.contentViewController as? BookmarkListController)?.table.cancelOperation(nil)
        try await waitClosed()
        try require(browser.bookmarkPopover?.isShown == false && browser.window?.firstResponder === browser.activeWebView,"Escape closes bookmark overflow and restores page focus")
        browser.showBookmarkOverflow(overflowButton); browser.activate(0)
        try await waitClosed()
        try require(browser.bookmarkPopover?.isShown == false,"switching tabs closes bookmark overflow")
        browser.showBookmarkOverflow(overflowButton); browser.focusAddress()
        try await waitClosed()
        try require(browser.bookmarkPopover?.isShown == false && browser.window?.firstResponder === browser.address.currentEditor(),"address shortcut dismisses bookmark overflow and focuses its editor")
        guard let searchButton = browser.window?.contentView?.subviews.flatMap({ $0.subviews }).compactMap({ $0 as? NSButton }).first(where:{$0.action == #selector(BrowserWindow.showTabList(_:))}) else { throw CaptureService.Failure.message("tab search button missing") }
        browser.showTabList(searchButton)
        guard let tabList = browser.tabPopover?.contentViewController as? TabListController else { throw CaptureService.Failure.message("tab search missing") }
        tabList.view.layoutSubtreeIfNeeded()
        guard let firstCell = tabList.table.view(atColumn:0,row:0,makeIfNecessary:true) else { throw CaptureService.Failure.message("tab search first row missing") }
        let listWidth = tabList.table.enclosingScrollView?.contentSize.width ?? 0
        try require(listWidth > 300 && firstCell.bounds.width >= listWidth-4 && firstCell.subviews.allSatisfy({ $0.frame.maxX <= firstCell.bounds.width }),"tab search titles fill the visible list without clipping: cell=\(firstCell.bounds.width), content=\(listWidth), table=\(tabList.table.bounds.width)")
        let originalID = browser.tabs[browser.activeIndex].id
        tabList.search.stringValue = "no-match-\(UUID())"; tabList.refresh(); tabList.openSelected()
        try require(tabList.matches.isEmpty && !tabList.emptyLabel.isHidden && browser.tabs[browser.activeIndex].id == originalID,"empty tab search explains no results and cannot navigate")
        browser.address.stringValue = "unfinished-address-draft"; browser.focusAddress()
        for _ in 0..<20 { if browser.tabPopover?.isShown != true { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(browser.tabPopover?.isShown == false && browser.window?.firstResponder === browser.address.currentEditor() && browser.address.stringValue == "unfinished-address-draft","address shortcut closes tab search and preserves the input draft")
        browser.showCommandPalette()
        let routed = NSApp.sendAction(#selector(BrowserWindow.focusAddress),to:nil,from:nil)
        try require(routed && browser.commandPalette?.window?.isVisible == false && browser.window?.isKeyWindow == true && browser.window?.firstResponder === browser.address.currentEditor() && browser.address.stringValue == "unfinished-address-draft","address menu action routes out of quick actions without discarding the draft")
        browser.address.stringValue = "书签"; browser.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:browser.address))
        try require(browser.suggestionPanel?.isVisible == true,"address fixture produces a real suggestion panel before switching search")
        browser.showTabList(searchButton)
        try require(browser.suggestionPanel == nil,"opening tab search removes stale address suggestions")
        browser.dismissTabList()
        for _ in 0..<20 { if browser.tabPopover?.isShown != true { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(browser.tabPopover?.isShown == false && browser.window?.firstResponder === browser.activeWebView,"dismissing tab search restores webpage focus")
        browser.showTabList(searchButton)
        guard let keyboardList = browser.tabPopover?.contentViewController as? TabListController else { throw CaptureService.Failure.message("tab search missing for table keyboard checks") }
        keyboardList.table.window?.makeFirstResponder(keyboardList.table)
        let previousTabID = browser.tabs[browser.activeIndex].id
        keyboardList.table.keyDown(with:key(125,in:keyboardList.table))
        try require(keyboardList.table.window?.firstResponder === keyboardList.table && keyboardList.table.selectedRow == 1 && browser.tabs[browser.activeIndex].id == previousTabID,"arrow selection in the focused tab table does not navigate prematurely")
        keyboardList.table.keyDown(with:key(36,in:keyboardList.table))
        for _ in 0..<20 { if browser.tabPopover?.isShown != true { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(browser.activeIndex == 1 && browser.tabPopover?.isShown == false,"Return from the tab table opens the selected tab")
        browser.showTabList(searchButton)
        let escapeTable = (browser.tabPopover?.contentViewController as? TabListController)?.table
        escapeTable?.window?.makeFirstResponder(escapeTable); escapeTable?.cancelOperation(nil)
        for _ in 0..<20 { if browser.tabPopover?.isShown != true { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(browser.tabPopover?.isShown == false && browser.window?.firstResponder === browser.activeWebView,"Escape from the tab table restores webpage focus")
        browser.activate(29); browser.showCommandPalette()
        guard let keyboardPalette = browser.commandPalette else { throw CaptureService.Failure.message("quick actions missing for table keyboard checks") }
        keyboardPalette.window?.makeFirstResponder(keyboardPalette.table)
        keyboardPalette.table.keyDown(with:key(125,in:keyboardPalette.table))
        try require(keyboardPalette.window?.firstResponder === keyboardPalette.table && keyboardPalette.table.selectedRow == 2 && browser.activeIndex == 29,"arrow selection in quick action results does not execute a command")
        keyboardPalette.table.keyDown(with:key(36,in:keyboardPalette.table))
        try require(browser.activeIndex == 1 && keyboardPalette.window?.isVisible == false,"Return from the quick action table opens the selected tab")
        browser.showCommandPalette()
        if let palette = browser.commandPalette { palette.window?.makeFirstResponder(palette.table); palette.table.cancelOperation(nil) }
        try require(browser.commandPalette?.window?.isVisible == false && browser.window?.firstResponder === browser.activeWebView,"Escape from quick action results restores webpage focus")
        browser.activate(29)
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
