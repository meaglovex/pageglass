import AppKit
import WebKit

@MainActor
enum DeveloperToolsSmoke {
    static func run(_ browser:BrowserWindow) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ label:String) throws {
            guard condition else { throw CaptureService.Failure.message(label) };checks.append(label)
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
        DeveloperTools.close(original)
        try await wait(inspector,visible:false)
        try await Task.sleep(for:.milliseconds(80))
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
        return checks
    }
}
