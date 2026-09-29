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
        let previousCount = browser.tabs.count
        browser.newTab()
        try require(host.window == nil,"switching tabs hides the entire previous inspector container")
        let another = browser.webView
        guard let otherInspector = DeveloperTools.inspector(for:another) else { throw CaptureService.Failure.message("second inspector unavailable") }
        try require(otherInspector !== inspector,"each tab owns its own inspector")
        try require(DeveloperTools.open(another),"second tab inspector opens independently")
        try await wait(otherInspector,visible:true)
        browser.closeTab()
        try await wait(otherInspector,visible:false)
        try require(browser.tabs.count == previousCount && !browser.tabs.contains { $0.webView === another } && browser.tabs.contains { $0.webView === original },"closing inspected tab releases only its own page and inspector")
        DeveloperTools.close(original)
        try await wait(inspector,visible:false)
        return checks
    }
}
