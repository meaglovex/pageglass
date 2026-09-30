import AppKit

/// Shared list feedback; the controller supplies the state and the recovery action.
final class PanelEmptyState:NSView {
    let heading = NSTextField(wrappingLabelWithString:"")
    let message = NSTextField(wrappingLabelWithString:"")
    let action = NSButton(title:"",target:nil,action:nil)
    private let icon = NSImageView()
    init() {
        super.init(frame:.zero)
        heading.font = .systemFont(ofSize:16,weight:.semibold); heading.alignment = .center
        message.font = BrowserStyle.body; message.textColor = BrowserStyle.supportingText; message.alignment = .center
        icon.contentTintColor = BrowserStyle.supportingText; icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant:28).isActive = true; icon.heightAnchor.constraint(equalToConstant:28).isActive = true
        action.bezelStyle = .rounded
        let content = NSStackView(views:[icon,heading,message,action]); content.orientation = .vertical; content.alignment = .centerX; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        let width = content.widthAnchor.constraint(equalToConstant:420); width.priority = .defaultHigh
        NSLayoutConstraint.activate([content.centerXAnchor.constraint(equalTo:centerXAnchor),content.centerYAnchor.constraint(equalTo:centerYAnchor),content.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-32),width,heading.widthAnchor.constraint(equalTo:content.widthAnchor),message.widthAnchor.constraint(equalTo:content.widthAnchor)])
    }
    required init?(coder:NSCoder) { fatalError() }
    func show(_ title:String,message text:String,symbol:String,actionTitle:String? = nil,target:AnyObject? = nil,selector:Selector? = nil) {
        heading.stringValue = title; message.stringValue = text
        icon.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
        action.title = actionTitle ?? ""; action.target = target; action.action = selector; action.isHidden = actionTitle == nil
    }
    func install(over scroll:NSScrollView)->NSView {
        let container = NSView()
        for view in [scroll,self] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:container.leadingAnchor),view.trailingAnchor.constraint(equalTo:container.trailingAnchor),view.topAnchor.constraint(equalTo:container.topAnchor),view.bottomAnchor.constraint(equalTo:container.bottomAnchor)])
        }
        isHidden = true; return container
    }
}
