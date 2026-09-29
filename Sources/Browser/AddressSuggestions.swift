import AppKit

extension BrowserWindow {
    func controlTextDidBeginEditing(_ notification:Notification) { if notification.object as? NSTextField === address { omnibox?.showsFocus = true } }
    func controlTextDidChange(_ notification:Notification) {
        guard notification.object as? NSTextField === address else { return }
        guard (address.currentEditor() as? NSTextView)?.hasMarkedText() != true else { dismissSuggestions(); return }
        suggestions = store.suggestions(address.stringValue); selectedSuggestion = -1; showSuggestions()
    }
    func controlTextDidEndEditing(_ notification:Notification) { if notification.object as? NSTextField === address { dismissSuggestions(); omnibox?.showsFocus = false } }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard control === address,!textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.moveDown(_:)),!suggestions.isEmpty { selectedSuggestion = min(suggestions.count-1,selectedSuggestion+1); showSuggestions(); return true }
        if selector == #selector(NSResponder.moveUp(_:)),!suggestions.isEmpty { selectedSuggestion = max(-1,selectedSuggestion-1); showSuggestions(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { navigate(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismissSuggestions(); window?.makeFirstResponder(webView); syncChrome(); return true }
        return false
    }
    func dismissSuggestions() {
        if let panel = suggestionPanel { window?.removeChildWindow(panel); panel.orderOut(nil) }
        suggestionPanel = nil; suggestions = []; selectedSuggestion = -1
    }
    private func showSuggestions() {
        guard !suggestions.isEmpty,let window else { dismissSuggestions(); return }
        let panel: NSPanel
        if let existing = suggestionPanel { panel = existing }
        else {
            panel = NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isFloatingPanel = false; panel.becomesKeyOnlyIfNeeded = true; panel.hasShadow = true; panel.backgroundColor = .controlBackgroundColor; panel.appearance = window.appearance
            suggestionPanel = panel; window.addChildWindow(panel,ordered:.above)
        }
        let row = NSStackView(); row.orientation = .vertical; row.spacing = 0; row.edgeInsets = NSEdgeInsets(top:6,left:6,bottom:6,right:6)
        let frame = window.convertToScreen(address.convert(address.bounds,to:nil))
        let width = min(max(420,frame.width),window.frame.width-32)
        for (index,item) in suggestions.enumerated() {
            let button = AddressSuggestionButton(title:"",target:self,action:#selector(suggestionClicked(_:)))
            let source = store.bookmark(for:item.url) == nil ? "历史" : "书签"
            button.heading = item.title; button.detail = "\(source) · \(item.url)"; button.isSelected = index == selectedSuggestion
            button.setAccessibilityLabel("\(item.title)，\(source)，\(item.url)")
            button.tag = index; button.isBordered = false; button.alignment = .left; button.lineBreakMode = .byTruncatingMiddle; button.font = .systemFont(ofSize:12)
            button.contentTintColor = index == selectedSuggestion ? .controlAccentColor : .labelColor
            row.addArrangedSubview(button); button.heightAnchor.constraint(equalToConstant:48).isActive = true; button.widthAnchor.constraint(equalToConstant:width-12).isActive = true
        }
        panel.contentView = row; let height = CGFloat(suggestions.count*48+12)
        panel.setFrame(NSRect(x:min(frame.minX,window.frame.maxX-width-12),y:frame.minY-height-7,width:width,height:height),display:true); panel.orderFront(nil)
    }
    @objc private func suggestionClicked(_ button:NSButton) { guard suggestions.indices.contains(button.tag) else { return }; let url = suggestions[button.tag].url; dismissSuggestions(); address.stringValue = url; navigate() }
}
