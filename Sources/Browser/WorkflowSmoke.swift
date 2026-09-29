import AppKit
import WebKit

@MainActor
enum WorkflowSmoke {
    static func run(_ browser:BrowserWindow,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ value:Bool,_ message:String) throws { if !value { throw CaptureService.Failure.message(message) }; checks.append(message) }
        let fixture = Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources")!
        browser.load(fixture)
        for _ in 0..<100 { if !browser.webView.isLoading,browser.webView.title == "工作台 · 捕获练习" { break }; try await Task.sleep(for:.milliseconds(50)) }
        let view = browser.webView
        browser.window?.makeKeyAndOrderFront(nil); browser.window?.makeFirstResponder(view)
        let tab = BrowserTab(url:fixture); tab.title = "快速操作专用标签"; browser.tabs.append(tab); browser.renderTabs()
        let palette = CommandPaletteController(browser:browser); palette.search.stringValue = "快速操作专用"; palette.refresh()
        try require(palette.results.count == 1,"quick action search filters an existing tab without navigating")
        let ime = NSTextView(); ime.setMarkedText("中",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        try require(!palette.control(palette.search,textView:ime,doCommandBy:#selector(NSResponder.insertNewline(_:))) && browser.tabs[browser.activeIndex].id != tab.id,"IME composition cannot execute a quick action")
        palette.choose()
        try require(browser.tabs[browser.activeIndex].id == tab.id,"quick action opens the matched existing tab")
        browser.close(at:browser.activeIndex)
        browser.showCommandPalette(); browser.commandPalette?.search.stringValue = "no-match-\(UUID())"; browser.commandPalette?.refresh()
        try require(browser.commandPalette?.results.isEmpty == true,"quick action no-results state contains no executable fallback")
        browser.commandPalette?.dismiss(restoreFocus:true)
        try require(browser.window?.firstResponder === browser.webView,"closing quick actions restores webpage focus")
        let focusedView = browser.webView
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let viewport = focusedView.bounds.size, windows = NSApp.windows.filter(\.isVisible).count
        browser.selectElement(); browser.window?.contentView?.layoutSubtreeIfNeeded()
        try require(focusedView.bounds.size == viewport,"selection controls overlay rather than resize the webpage")
        let service = browser.captureService
        _ = try await service.js(focusedView,"globalThis.__pageglass.selectForTest('#metric-card'); globalThis.__pageglass.selectParent()")
        let parent = try await service.js(focusedView,"globalThis.__pageglass.extract('element').selector") as? String
        try require(parent != nil && parent != "#metric-card","parent selection moves to the observed DOM ancestor")
        browser.cancelCapture()
        let settings = browser.store.state.settings
        var manual = settings; manual.autoCopyCapture = false; browser.store.updateSettings(manual)
        defer { browser.store.updateSettings(settings); browser.hideCaptureSidebar() }
        var paths = Set<String>(), sidebar:CaptureSidebar?
        for _ in 0..<10 {
            _ = try await service.js(focusedView,"globalThis.__pageglass.selectForTest('#metric-card')")
            browser.performCapture(mode:"element"); await browser.captureTask?.value
            guard let result = browser.latest else { throw CaptureService.Failure.message("consecutive capture failed") }
            paths.insert(result.directory.path)
            browser.window?.contentView?.layoutSubtreeIfNeeded()
            if let sidebar { try require(browser.captureSidebar === sidebar,"successive capture reuses the same sidebar") } else { sidebar = browser.captureSidebar }
            guard focusedView.bounds.size == viewport else { throw CaptureService.Failure.message("capture results changed webpage viewport") }
        }
        try require(paths.count == 10 && NSApp.windows.filter(\.isVisible).count == windows,"ten completed captures create ten packages without extra windows")
        try require(browser.captureSidebar?.isHidden == false && focusedView.bounds.size == viewport,"capture sidebar leaves the original webpage viewport intact")
        browser.cancelOperation(nil)
        try require(browser.captureSidebar?.isHidden == true && browser.window?.firstResponder === focusedView,"Escape closes capture results and returns webpage focus")
        if let result = browser.latest { browser.showCaptureResult(result) }
        browser.selectElement()
        try require(browser.captureSidebar?.isHidden == true && browser.selecting,"starting the next selection hides the previous result")
        browser.cancelCapture()
        if let result = browser.latest {
            browser.showCaptureResult(result)
            for _ in 0..<100 { if browser.captureSidebar?.detail.hasUsableActions == true { break }; try await Task.sleep(for:.milliseconds(20)) }
            try require(browser.captureSidebar?.detail.hasUsableActions == true,"valid capture exposes its copy and preview actions")
            let moved = output.appendingPathComponent("removed-preview-fixture")
            try FileManager.default.moveItem(at:result.directory,to:moved)
            defer { try? FileManager.default.moveItem(at:moved,to:result.directory) }
            NotificationCenter.default.post(name:CaptureRetention.changed,object:browser.captureRoot)
            for _ in 0..<100 { if browser.captureSidebar?.detail.hasUsableActions == false { break }; try await Task.sleep(for:.milliseconds(20)) }
            try require(browser.captureSidebar?.detail.hasUsableActions == false,"capture cleanup notification disables stale copy and preview actions")
        }
        return checks
    }
}
