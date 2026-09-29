import AppKit

/// Layout regression checks in real AppKit windows; manual visual/keyboard acceptance remains separate.
@MainActor
enum ChromeLayoutSmoke {
    static func run(output:URL) async throws->[String] {
        let store = BrowserStore(directory:output.appendingPathComponent("chrome-profile"))
        let browser = BrowserWindow(store:store)
        browser.showWindow(nil)
        defer { browser.close() }
        var checks:[String] = [], rows:[[String:Any]] = []
        func require(_ condition:Bool,_ label:String) throws {
            guard condition else { throw CaptureService.Failure.message(label) }; checks.append(label)
        }
        for theme in ["light","dark"] {
            var settings = store.state.settings; settings.appearance = theme; store.updateSettings(settings)
            for count in [1,10,30] {
                for tab in browser.tabs { tab.release() }
                browser.tabs = (0..<count).map { index in let tab = BrowserTab(); tab.title = "\(index+1) · 长标题产品需求与交互验收"; return tab }
                browser.activeIndex = 0; browser.activate(count-1)
                for width in [900.0,1280.0,1440.0] {
                    browser.window?.setContentSize(NSSize(width:width,height:860))
                    browser.renderTabs(revealActive:true); browser.updateToolbarLayout()
                    browser.window?.contentView?.layoutSubtreeIfNeeded()
                    try await Task.sleep(for:.milliseconds(50))
                    guard let root = browser.window?.contentView,let active = browser.tabButtons[browser.tabs.last!.id] else { throw CaptureService.Failure.message("Missing active tab") }
                    let controls = [browser.back,browser.forward,browser.refresh,browser.pick,browser.captureMenuButton] as [NSView]
                    let reachable = controls.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && root.bounds.contains($0.convert($0.bounds,to:root)) && $0.bounds.width >= 28 && $0.bounds.height >= 28 }
                    let addressRect = browser.address.convert(browser.address.bounds,to:root)
                    let closeRect = active.closeButton.convert(active.closeButton.bounds,to:browser.tabScroll.contentView)
                    let visibleClose = browser.tabScroll.contentView.bounds.contains(closeRect)
                    let stripWidth = browser.tabScroll.bounds.width
                    let caseName = "\(theme) \(Int(width))pt \(count)tabs"
                    if !(reachable && addressRect.width >= 180 && visibleClose) {
                        print("LAYOUT DIAGNOSTIC \(caseName): root=\(root.bounds), address=\(addressRect), close=\(closeRect), clip=\(browser.tabScroll.contentView.bounds)")
                        for control in controls { print("control \(control.accessibilityLabel() ?? "?"): bounds=\(control.bounds), root=\(control.convert(control.bounds,to:root)), hidden=\(control.isHiddenOrHasHiddenAncestor)") }
                    }
                    try require(reachable && addressRect.width >= 180 && visibleClose,"\(caseName): primary controls and active close button remain reachable")
                    if count == 1 { try require(stripWidth <= 231,"\(caseName): new tab button follows the single tab") }
                    rows.append(["theme":theme,"windowWidth":width,"tabs":count,"addressWidth":addressRect.width,"tabStripWidth":stripWidth,"primaryControlsReachable":reachable,"activeCloseVisible":visibleClose])
                }
            }
        }
        try JSONSerialization.data(withJSONObject:["status":"passed","cases":rows,"scope":"Native frame checks; not a substitute for screenshots, IME or VoiceOver acceptance"],options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("chrome-layout.json"))
        return checks
    }
}
