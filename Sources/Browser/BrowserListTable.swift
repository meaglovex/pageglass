import AppKit

/// Shared Return/Escape behavior after Tab moves focus from search to results.
final class BrowserListTable:NSTableView {
    var openSelection:(()->Void)?
    var dismiss:(()->Void)?
    var contextMenu:((Int)->NSMenu?)?
    override func keyDown(with event:NSEvent) {
        switch event.keyCode {
        case 36,76: openSelection?()
        case 53: dismiss?()
        default: super.keyDown(with:event)
        }
    }
    override func cancelOperation(_ sender:Any?) { dismiss?() }
    override func menu(for event:NSEvent)->NSMenu? {
        let row = row(at:convert(event.locationInWindow,from:nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        return contextMenu?(row)
    }
    override func rightMouseDown(with event:NSEvent) {
        if let menu = menu(for:event) { NSMenu.popUpContextMenu(menu,with:event,for:self) }
    }
}
