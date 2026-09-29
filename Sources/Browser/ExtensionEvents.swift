import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor
struct ExtensionTabSnapshot {
    let tab:BrowserTab
    let url:URL?,title:String,loading:Bool
    let zoom:CGFloat
    init(_ tab:BrowserTab) {
        self.tab = tab; url = tab.webView?.url ?? tab.url; title = tab.title
        loading = tab.webView?.isLoading ?? false; zoom = tab.webView?.pageZoom ?? 1
    }
}

@available(macOS 15.4, *)
extension ExtensionRuntime {
    func opened(_ window:BrowserWindow) {
        windows.add(window); sync(window)
    }
    func closed(_ window:BrowserWindow) {
        closePopup()
        for snapshot in tabSnapshots.removeValue(forKey:window.id) ?? [] { controller.didCloseTab(snapshot.tab,windowIsClosing:true) }
        activeTabs.removeValue(forKey:window.id)
        if visibleWindows.remove(window.id) != nil { controller.didCloseWindow(window) }
        windows.remove(window)
    }
    func sync(_ window:BrowserWindow) {
        guard windows.contains(window),!window.privateBrowsing else { return }
        if !window.extensionWindowVisible {
            for snapshot in tabSnapshots.removeValue(forKey:window.id) ?? [] { controller.didCloseTab(snapshot.tab,windowIsClosing:true) }
            activeTabs.removeValue(forKey:window.id)
            if visibleWindows.remove(window.id) != nil { controller.didCloseWindow(window) }
            return
        }
        if visibleWindows.insert(window.id).inserted { controller.didOpenWindow(window) }
        let old = tabSnapshots[window.id] ?? [],next = window.tabs.filter(\.extensionVisible).map(ExtensionTabSnapshot.init)
        let oldIDs = Set(old.map { $0.tab.id }),nextIDs = Set(next.map { $0.tab.id })
        // Publish the snapshot first: delegate reads during event delivery see the current state.
        tabSnapshots[window.id] = next
        for item in old where !nextIDs.contains(item.tab.id) { controller.didCloseTab(item.tab) }
        for item in next where !oldIDs.contains(item.tab.id) { controller.didOpenTab(item.tab) }
        for item in next {
            guard let previousIndex = old.firstIndex(where:{$0.tab === item.tab}) else { continue }
            let previous = old[previousIndex]
            var changes:WKWebExtension.TabChangedProperties = []
            if previous.url != item.url { changes.insert(.URL) }
            if previous.title != item.title { changes.insert(.title) }
            if previous.loading != item.loading { changes.insert(.loading) }
            if previous.zoom != item.zoom { changes.insert(.zoomFactor) }
            if !changes.isEmpty { controller.didChangeTabProperties(changes,for:item.tab) }
        }
        let active = window.tabs.indices.contains(window.activeIndex) ? window.tabs[window.activeIndex] : nil
        let visible = active?.extensionVisible == true ? active : nil,previous = activeTabs[window.id]
        activeTabs[window.id] = visible
        if let visible,previous !== visible { controller.didActivateTab(visible,previousActiveTab:previous) }
    }
}
