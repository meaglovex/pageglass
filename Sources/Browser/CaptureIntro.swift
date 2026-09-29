import AppKit

/// One small native prompt, without changing the webpage viewport or taking typing focus.
final class CaptureIntroView:ChromeStackView {
    weak var browser:BrowserWindow?
    init(browser:BrowserWindow) {
        self.browser = browser; super.init(frame:.zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        edgeInsets = NSEdgeInsets(top:16,left:18,bottom:16,right:18)
        surfaceColor = .controlBackgroundColor; cornerRadius = 10; showsBorder = true
        let heading = NSTextField(labelWithString:"把网页交给 Codex 改原型"); heading.font = .systemFont(ofSize:15,weight:.semibold)
        let description = NSTextField(wrappingLabelWithString:"① 点击「捕获」，选择网页元素\n② 检查截图，补充标注或修改要求\n③ 在本机 Codex 粘贴，继续做原型")
        description.font = BrowserStyle.body
        let hint = NSTextField(wrappingLabelWithString:"复制的是本机文件引用。先用练习页试一次，无需登录。")
        hint.font = BrowserStyle.caption; hint.textColor = BrowserStyle.supportingText
        let practice = NSButton(title:"开始练习",target:browser,action:#selector(BrowserWindow.startCapturePractice)); practice.bezelStyle = .rounded
        let dismiss = NSButton(title:"知道了",target:browser,action:#selector(BrowserWindow.dismissCaptureIntro)); dismiss.bezelStyle = .rounded
        let row = NSStackView(views:[practice,dismiss]); row.spacing = 8
        for view in [heading,description,hint,row] { addArrangedSubview(view); view.widthAnchor.constraint(equalTo:widthAnchor,constant:-36).isActive = true }
        setAccessibilityRole(.group); setAccessibilityLabel("Pageglass 捕获入门")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func cancelOperation(_ sender:Any?) { browser?.dismissCaptureIntro() }
}

extension BrowserWindow {
    var canOfferCaptureIntro:Bool { !privateBrowsing && store.isFreshProfile && store.error == nil && store.state.settings.captureIntroSeen != true }
    func offerCaptureIntroIfNeeded() {
        guard !isTesting,canOfferCaptureIntro,window?.isVisible == true,window?.isKeyWindow == true,
              activeWebView?.url == Resources.bundle.url(forResource:"home",withExtension:"html",subdirectory:"Resources"),activeWebView?.isLoading == false else { return }
        showCaptureIntro()
    }
    @objc func showCaptureIntro() {
        guard !capturing,!selecting,captureIntro == nil else { return }
        hideCaptureSidebar()
        let intro = CaptureIntroView(browser:self); captureIntro = intro
        intro.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(intro)
        NSLayoutConstraint.activate([intro.widthAnchor.constraint(equalToConstant:360),intro.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-18),intro.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-48)])
        // Mark display, not only a button click: navigation and window closure must not repeat it.
        if !privateBrowsing,store.state.settings.captureIntroSeen != true {
            var settings = store.state.settings; settings.captureIntroSeen = true; store.updateSettings(settings)
        }
    }
    @objc func dismissCaptureIntro() {
        let focused = captureIntro.map { intro in (window?.firstResponder as? NSView)?.isDescendant(of:intro) == true } ?? false
        captureIntro?.removeFromSuperview(); captureIntro = nil
        if focused { window?.makeFirstResponder(activeWebView) }
    }
    @objc func startCapturePractice() {
        guard !capturing else { return }; dismissCaptureIntro()
        guard let demo = Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources") else { return }
        if activeWebView?.url == Resources.bundle.url(forResource:"home",withExtension:"html",subdirectory:"Resources") { load(demo) }
        else { openTab(demo) }
    }
}
