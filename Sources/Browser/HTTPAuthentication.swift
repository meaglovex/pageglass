import AppKit
import WebKit

/// HTTP Basic / Digest / NTLM sign-in for the page being shown. TLS, client certificates and Kerberos keep
/// WebKit's default handling. Credentials live only in the tab's website data session, never in browser.json.
enum HTTPAuthentication {
    static let promptedMethods:Set<String> = [NSURLAuthenticationMethodHTTPBasic,NSURLAuthenticationMethodHTTPDigest,NSURLAuthenticationMethodNTLM]
    static let maximumAttempts = 5

    /// A proxy, or the origin of the page being shown or opened, may ask. A cross-origin subresource cannot raise a password sheet.
    static func shouldPrompt(_ space:URLProtectionSpace,page:URL?,pending:URL?,failures:Int)->Bool {
        guard promptedMethods.contains(space.authenticationMethod),failures < maximumAttempts else { return false }
        if space.isProxy() { return true }
        return [page,pending].contains { url in
            guard let url,let scheme = url.scheme?.lowercased(),scheme == space.protocol?.lowercased(),let host = url.host?.lowercased() else { return false }
            return host == space.host.lowercased() && (url.port ?? (scheme == "https" ? 443 : 80)) == space.port
        }
    }
    static func title(_ space:URLProtectionSpace)->String { space.isProxy() ? "代理服务器 \(space.host) 需要登录" : "登录 \(space.host)" }
    static func notice(_ space:URLProtectionSpace,failures:Int)->String {
        var lines:[String] = []
        if failures > 0 { lines.append("用户名或密码不正确，请重试。") }
        // The realm is server text: show it as a quoted hint, never as browser instructions.
        if let realm = space.realm?.trimmingCharacters(in:.whitespacesAndNewlines),!realm.isEmpty { lines.append("网站提示（不可信）：「\(String(realm.prefix(120)))」") }
        if !space.receivesCredentialSecurely { lines.append("此连接未加密，用户名和密码可能被网络中的他人读取。") }
        lines.append("凭据只在当前浏览会话中使用，不写入书签、历史或设置。")
        return lines.joined(separator:"\n")
    }
}

extension BrowserWindow {
    func webView(_ webView:WKWebView,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        let space = challenge.protectionSpace
        guard let window,window.isVisible,webView === activeWebView,let tab = tabs.first(where:{$0.webView === webView}),tab.dialog == nil,
              HTTPAuthentication.shouldPrompt(space,page:webView.url,pending:tab.pendingURL,failures:challenge.previousFailureCount) else {
            completionHandler(.performDefaultHandling,nil); return
        }
        let alert = NSAlert(); alert.messageText = HTTPAuthentication.title(space)
        alert.informativeText = HTTPAuthentication.notice(space,failures:challenge.previousFailureCount)
        let user = NSTextField(), password = NSSecureTextField()
        user.placeholderString = "用户名"; user.setAccessibilityLabel("用户名"); user.stringValue = challenge.proposedCredential?.user ?? ""
        password.placeholderString = "密码"; password.setAccessibilityLabel("密码")
        let fields = NSStackView(views:[user,password]); fields.orientation = .vertical; fields.spacing = 8
        fields.frame = NSRect(x:0,y:0,width:300,height:60)
        for field in [user,password] { field.translatesAutoresizingMaskIntoConstraints = false; field.widthAnchor.constraint(equalToConstant:300).isActive = true }
        alert.accessoryView = fields
        alert.addButton(withTitle:"登录"); alert.addButton(withTitle:"取消")
        tab.dialog = alert
        alert.beginSheetModal(for:window) { [weak tab] response in
            tab?.dialog = nil
            guard response == .alertFirstButtonReturn,!user.stringValue.isEmpty else { completionHandler(.performDefaultHandling,nil); return }
            completionHandler(.useCredential,URLCredential(user:user.stringValue,password:password.stringValue,persistence:.forSession))
        }
        alert.window.makeFirstResponder(user.stringValue.isEmpty ? user : password)
    }
}
