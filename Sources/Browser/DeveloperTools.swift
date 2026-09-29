import AppKit
import WebKit
import ObjectiveC

/// Local-build exception authorized by the user. Keep private WebKit calls here,
/// check their ABI before dispatch, and fall back instead of sending unknown selectors.
@MainActor
enum DeveloperTools {
    private static func method(_ object:NSObject,_ name:String,returns:String,args:[String] = [])->IMP? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to:selector),let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls,selector),method_getNumberOfArguments(method) == args.count+2 else { return nil }
        let result = method_copyReturnType(method)
        defer { free(result) }
        guard returns.contains(String(cString:result).prefix(1)) else { return nil }
        for (index,allowed) in args.enumerated() {
            guard let type = method_copyArgumentType(method,UInt32(index+2)) else { return nil }
            defer { free(type) }
            guard allowed.contains(String(cString:type).prefix(1)) else { return nil }
        }
        return method_getImplementation(method)
    }
    @discardableResult
    static func enable(_ preferences:WKPreferences)->Bool {
        let name = "_setDeveloperExtrasEnabled:"
        guard let imp = method(preferences,name,returns:"v",args:["Bc"]) else { return false }
        typealias Setter = @convention(c) (AnyObject,Selector,Bool)->Void
        unsafeBitCast(imp,to:Setter.self)(preferences,NSSelectorFromString(name),true)
        return true
    }
    static func inspector(for view:WKWebView)->NSObject? {
        guard method(view,"_inspector",returns:"@") != nil else { return nil }
        return view.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject
    }
    static func visible(_ inspector:NSObject)->Bool? {
        guard let imp = method(inspector,"isVisible",returns:"Bc") else { return nil }
        typealias Getter = @convention(c) (AnyObject,Selector)->Bool
        return unsafeBitCast(imp,to:Getter.self)(inspector,NSSelectorFromString("isVisible"))
    }
    @discardableResult
    static func call(_ inspector:NSObject,_ name:String)->Bool {
        guard let imp = method(inspector,name,returns:"v") else { return false }
        typealias Action = @convention(c) (AnyObject,Selector)->Void
        unsafeBitCast(imp,to:Action.self)(inspector,NSSelectorFromString(name))
        return true
    }
    static func open(_ view:WKWebView,console:Bool = false,toggle:Bool = true)->Bool {
        guard enable(view.configuration.preferences),let inspector = inspector(for:view),let shown = visible(inspector) else { return false }
        if shown && toggle && !console {
            guard call(inspector,"close") else { return false }
            view.window?.makeFirstResponder(view)
            return true
        }
        guard call(inspector,console ? "showConsole" : "show") else { return false }
        if !shown { _ = call(inspector,"attach") }
        return true
    }
    static func close(_ view:WKWebView) {
        guard let inspector = inspector(for:view),visible(inspector) == true else { return }
        _ = call(inspector,"close")
    }
}

extension BrowserWindow {
    @objc func showDeveloperTools() { openDeveloperTools(console:false) }
    @objc func showJavaScriptConsole() { openDeveloperTools(console:true) }
    private func openDeveloperTools(console:Bool) {
        guard let view = activeWebView else { return }
        if !DeveloperTools.open(view,console:console) { showInspectorHelp() }
    }
    @objc func showInspectorHelp() {
        let alert = NSAlert();alert.messageText = "网页检查器兼容帮助"
        alert.informativeText = "F12 / ⌥⌘I 打开或关闭检查器；⌥⌘J 打开控制台。\n\n如果当前 macOS 不支持本地检查器接口，可在 Safari 设置 → 高级中开启“显示网页开发者功能”，然后在“开发 → 此 Mac → Pageglass”中选择页面。"
        alert.addButton(withTitle:"关闭");alert.addButton(withTitle:"打开 Safari")
        guard alert.runModal() == .alertSecondButtonReturn,let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Safari") else { return }
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
    }
}
