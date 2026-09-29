import AppKit

struct PageFailure {
    let message: String
    let url: URL?
}

extension BrowserWindow {
    func buildErrorBar() {
        errorBar.orientation = .horizontal; errorBar.spacing = 10
        errorBar.edgeInsets = NSEdgeInsets(top:8,left:14,bottom:8,right:14)
        errorBar.wantsLayer = true; errorBar.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        errorLabel.font = .systemFont(ofSize:12); errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        errorBar.addArrangedSubview(errorLabel)
        for (title,action) in [("重试",#selector(retryFailedPage)),("编辑地址",#selector(editFailedAddress))] {
            let button = NSButton(title:title,target:self,action:action); button.bezelStyle = .rounded
            errorBar.addArrangedSubview(button)
        }
        errorBar.isHidden = true
    }
    func syncPageFailure() {
        guard tabs.indices.contains(activeIndex),let failure = tabs[activeIndex].failure else { errorBar.isHidden = true; return }
        errorLabel.stringValue = failure.message; errorLabel.toolTip = failure.message
        errorBar.isHidden = false
        for button in errorBar.arrangedSubviews.compactMap({ $0 as? NSButton }) { button.isEnabled = !capturing }
    }
    @objc func retryFailedPage() {
        guard !capturing,tabs.indices.contains(activeIndex),let failure = tabs[activeIndex].failure else { return }
        if let url = failure.url { load(url) } else { reload() }
    }
    @objc func editFailedAddress() {
        guard !capturing else { return }
        focusAddress()
        if let url = tabs[activeIndex].failure?.url { address.stringValue = url.absoluteString; address.selectText(nil) }
    }
}
