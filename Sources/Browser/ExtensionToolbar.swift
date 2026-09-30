import AppKit
import WebKit

extension BrowserWindow {
    /// Keep the address field usable; overflow remains reachable through the collection menu.
    func updateExtensionActions() {
        var visible:[InstalledExtension] = []
        if #available(macOS 15.4,*),!privateBrowsing,let runtime = extensions {
            let width = window?.frame.width ?? 1280,limit = width >= 1100 ? 3 : width >= 1040 ? 2 : width >= 900 ? 1 : 0
            visible = Array(runtime.repository.state.items.filter {
                $0.toolbarVisible == true && $0.enabled && runtime.action($0.id,browser:self) != nil
            }.prefix(limit))
        }
        let ids = Set(visible.map(\.id))
        for id in Array(extensionActionButtons.keys) where !ids.contains(id) {
            if let button = extensionActionButtons.removeValue(forKey:id) { extensionActionBar.removeArrangedSubview(button); button.removeFromSuperview() }
        }
        if #available(macOS 15.4,*),let runtime = extensions,!privateBrowsing {
            for (index,record) in visible.enumerated() {
                guard let action = runtime.action(record.id,browser:self) else { continue }
                let button:ChromeButton
                if let existing = extensionActionButtons[record.id] { button = existing }
                else {
                    button = ChromeButton(); configure(button,"puzzlepiece.extension",record.name,#selector(runToolbarExtension(_:)))
                    button.identifier = .init(record.id.uuidString); button.imageScaling = .scaleProportionallyDown
                    extensionActionButtons[record.id] = button; extensionActionBar.insertArrangedSubview(button,at:index)
                }
                button.image = action.icon(for:CGSize(width:18,height:18)) ?? NSImage(systemSymbolName:"puzzlepiece.extension",accessibilityDescription:record.name)
                let label = action.label.isEmpty || action.label == record.name ? record.name : record.name+" · "+action.label
                button.toolTip = label+(action.badgeText.isEmpty ? "" : " · "+action.badgeText)
                button.setAccessibilityLabel(button.toolTip); button.isEnabled = !runtime.busy && !capturing && action.isEnabled
            }
        }
        extensionActionBar.isHidden = visible.isEmpty
    }
    @objc func runToolbarExtension(_ sender:NSButton) {
        guard let value = sender.identifier?.rawValue,let id = UUID(uuidString:value) else { return }
        if #available(macOS 15.4,*) { extensions?.performAction(id,browser:self) }
    }
}

@available(macOS 15.4,*)
extension ExtensionRuntime {
    func action(_ id:UUID,browser:BrowserWindow)->WKWebExtension.Action? {
        // WebKit also supplies a default Action for content-only extensions.
        // Only expose a runnable control when the extension declares one.
        guard !browser.privateBrowsing,let context = contexts[id],context.isLoaded,
              context.webExtension.manifest["action"] is [String:Any] else { return nil }
        let tab = browser.tabs.indices.contains(browser.activeIndex) ? browser.tabs[browser.activeIndex] : nil
        return context.action(for:tab?.extensionVisible == true ? tab : nil)
    }
}
