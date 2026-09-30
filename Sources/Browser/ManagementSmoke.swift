import AppKit

@MainActor
enum ManagementSmoke {
    static func run(output:URL) throws->[String] {
        var checks:[String] = []
        func require(_ value:Bool,_ label:String) throws { if !value { throw CaptureService.Failure.message(label) }; checks.append(label) }
        let store = BrowserStore(directory:output.appendingPathComponent("management-store"))
        let browser = BrowserWindow(store:store), library = LibraryController(browser:browser)
        defer { library.close(); browser.window?.close() }
        for mode in [LibraryController.Mode.bookmarks,.history,.downloads] {
            library.show(mode)
            try require(!library.emptyState.isHidden && !library.primary.isEnabled && !library.secondary.isEnabled,"empty \(mode) explains the next step without enabling record actions")
        }
        store.toggleBookmark(title:"管理窗口保留的书签",url:"https://example.test/management")
        library.show(.bookmarks); library.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        library.search.stringValue = "missing-result"; library.searchChanged()
        try require(!library.emptyState.isHidden && !library.emptyState.action.isHidden && !library.edit.isEnabled,"unmatched search clears stale selection and offers recovery")
        let action = library.emptyState.action
        guard let selector = action.action else { throw CaptureService.Failure.message("search recovery action missing") }
        _ = NSApp.sendAction(selector,to:action.target,from:action)
        try require(library.search.stringValue.isEmpty && library.pages.count == 1 && library.emptyState.isHidden && library.search.currentEditor() != nil,"clearing search restores saved records and keyboard focus")
        for theme in [NSAppearance.Name.aqua,.darkAqua] {
            library.window?.appearance = NSAppearance(named:theme); library.window?.setContentSize(NSSize(width:600,height:420)); library.search.stringValue = "missing"; library.refresh()
            library.window?.contentView?.layoutSubtreeIfNeeded()
            let panel = library.emptyState, actionRect = action.convert(action.bounds,to:panel)
            try require(panel.bounds.contains(actionRect) && actionRect.height >= 20,"\(theme.rawValue) narrow management window keeps recovery action visible")
        }
        let brokenDirectory = output.appendingPathComponent("management-broken-store")
        try FileManager.default.createDirectory(at:brokenDirectory,withIntermediateDirectories:true)
        let broken = Data("{broken-owned-fixture".utf8), file = brokenDirectory.appendingPathComponent("browser.json")
        try broken.write(to:file)
        let badStore = BrowserStore(directory:brokenDirectory), badBrowser = BrowserWindow(store:badStore), badLibrary = LibraryController(browser:badBrowser)
        defer { badLibrary.close(); badBrowser.window?.close() }
        badLibrary.show(.bookmarks)
        try require(badStore.error != nil && badLibrary.emptyState.heading.stringValue == "资料读取失败" && (try Data(contentsOf:file)) == broken,"corrupt profile is identified as unreadable and its original data is preserved")
        return checks
    }
}
