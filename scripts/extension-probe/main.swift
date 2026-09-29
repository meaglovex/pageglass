import AppKit
import WebKit

// A separate, explicit executable. Fixtures and stores never enter the installed browser profile.
@available(macOS 15.4, *)
@MainActor
final class Probe:NSObject,NSApplicationDelegate,WKWebExtensionControllerDelegate,WKWebExtensionWindow,WKWebExtensionTab,WKScriptMessageHandler {
    let controller:WKWebExtensionController
    let websiteDataID = UUID()
    let websiteDataStore:WKWebsiteDataStore
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    var view:WKWebView!
    var contexts:[WKWebExtensionContext] = []
    var popup:NSPopover?
    var checks:[String] = []
    var failures:[String] = []
    let output:URL
    let base:URL
    init(output:URL,base:URL) {
        self.output = output; self.base = base
        websiteDataStore = WKWebsiteDataStore(forIdentifier:websiteDataID)
        let configuration = WKWebExtensionController.Configuration(identifier:UUID())
        configuration.defaultWebsiteDataStore = websiteDataStore
        controller = WKWebExtensionController(configuration:configuration)
        super.init(); controller.delegate = self
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        let config = WKWebViewConfiguration(); config.websiteDataStore = websiteDataStore; config.webExtensionController = controller
        config.userContentController.add(self,contentWorld:.world(name:"dev.pageglass.capture"),name:"pageglass")
        view = WKWebView(frame:NSRect(x:0,y:0,width:1000,height:700),configuration:config)
        window.title = "Pageglass 0.8 · Extension API probe"; window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        Task { await run() }
    }
    func require(_ condition:Bool,_ name:String) throws {
        guard condition else { throw NSError(domain:"ExtensionProbe",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
        checks.append(name); print("PASS \(name)")
    }
    func wait(_ condition:() async throws->Bool) async throws {
        for _ in 0..<100 { if try await condition() { return }; try await Task.sleep(for:.milliseconds(100)) }
        throw NSError(domain:"ExtensionProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for extension state"])
    }
    func fixture(_ name:String,manifest:[String:Any],files:[String:String]) async throws->WKWebExtensionContext {
        let directory = output.appendingPathComponent(name,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var manifest = manifest; manifest["description"] = "Owned Pageglass API validation fixture."
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted]).write(to:directory.appendingPathComponent("manifest.json"))
        for (name,text) in files { try text.write(to:directory.appendingPathComponent(name),atomically:true,encoding:.utf8) }
        let ext = try await WKWebExtension(resourceBaseURL:directory)
        if !ext.errors.isEmpty { throw NSError(domain:"ExtensionProbe",code:4,userInfo:[NSLocalizedDescriptionKey:ext.errors.map { $0.localizedDescription }.joined(separator:"; ")]) }
        try require(ext.errors.isEmpty,"\(name): manifest parsed without errors")
        let context = WKWebExtensionContext(for:ext)
        let identity = UUID().uuidString.lowercased()
        context.uniqueIdentifier = identity; context.baseURL = URL(string:"webkit-extension://"+identity+"/")!
        context.isInspectable = true; context.hasAccessToPrivateData = false
        context.unsupportedAPIs = ["browser.scripting.executeScript","browser.scripting.registerContentScripts","browser.scripting.updateContentScripts","browser.tabs.executeScript","browser.runtime.sendNativeMessage","browser.runtime.connectNative"]
        contexts.append(context)
        return context
    }
    func loadPage() async throws {
        view.load(URLRequest(url:base.appendingPathComponent("extension-page")))
        try await wait { guard !self.view.isLoading,self.view.url?.lastPathComponent == "extension-page" else { return false }; return try await self.view.evaluateJavaScript("document.readyState") as? String == "complete" }
    }
    func injected() async throws->String? { try await view.evaluateJavaScript("document.documentElement.dataset.extensionProbe") as? String }
    func request(_ name:String) async throws->Bool {
        try await view.callAsyncJavaScript("try { const response = await fetch(path + '?n=' + Math.random()); return response.ok; } catch { return false; }",arguments:["path":"/"+name],in:nil,contentWorld:.world(name:"dev.pageglass.extension-probe")) as? Bool == true
    }
    func run() async {
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let action = try await fixture("popup-storage",manifest:["manifest_version":3,"name":"Pageglass storage probe","version":"1.0","permissions":["storage"],"action":["default_popup":"popup.html"],"background":["service_worker":"worker.js"]],files:[
                "popup.html":"<!doctype html><meta charset=utf-8><title>Extension probe</title><style>body{width:300px;padding:20px;font:14px system-ui}</style><h1>Storage probe</h1><output id=result>Loading…</output><script src=popup.js></script>",
                "popup.js":"(async()=>{try {const previous=await browser.storage.local.get('count'); const count=(previous.count||0)+1; await browser.storage.local.set({count}); const reply=await browser.runtime.sendMessage({ping:true}); const result={count,reply,name:browser.runtime.getManifest().name,captureBridge:!!globalThis.webkit?.messageHandlers?.pageglass,executeScript:typeof browser.scripting?.executeScript}; document.querySelector('output').textContent=JSON.stringify(result);document.body.dataset.ready='true';}catch(error){document.querySelector('output').textContent=String(error);document.body.dataset.ready='error';}})();",
                "worker.js":"browser.runtime.onMessage.addListener((message,sender,reply)=>{reply({pong:message.ping===true});});"
            ])
            action.setPermissionStatus(.grantedExplicitly,for:.storage)
            try controller.load(action); controller.didOpenWindow(self)
            try await loadPage()
            action.performAction(for:self)
            try await wait { self.popup?.isShown == true }
            guard let actionView = action.action(for:self)?.popupWebView else { throw NSError(domain:"ExtensionProbe",code:3) }
            try await wait { try await actionView.evaluateJavaScript("document.body?.dataset.ready") as? String == "true" }
            let first = try await actionView.evaluateJavaScript("JSON.parse(document.querySelector('output').textContent)") as? [String:Any] ?? [:]
            try require(first["count"] as? Int == 1,"popup storage writes and reads")
            try require((first["reply"] as? [String:Any])?["pong"] as? Bool == true,"popup messages reach MV3 worker")
            try require(first["captureBridge"] as? Bool == false,"extension popup has no capture native bridge")
            try require(first["executeScript"] as? String == "undefined","unsupported programmatic script API is unavailable")
            try await wait { self.popup?.isShown == true }
            try require(popup?.isShown == true,"host presents real extension popup")
            popup?.close(); popup = nil
            try controller.unload(action); try controller.load(action); action.performAction(for:self)
            try await wait { self.popup?.isShown == true }
            guard let secondView = action.action(for:self)?.popupWebView else { throw NSError(domain:"ExtensionProbe",code:3) }
            try await wait { try await secondView.evaluateJavaScript("document.body?.dataset.ready") as? String == "true" }
            let secondCount = try await secondView.evaluateJavaScript("JSON.parse(document.querySelector('output').textContent).count") as? Int
            print("Reloaded storage count: \(String(describing:secondCount))")
            try require(secondCount == 2,"extension storage survives unload and reload")
            popup?.close(); popup = nil
            let content = try await fixture("site-content",manifest:["manifest_version":3,"name":"Pageglass site probe","version":"1.0","content_scripts":[["matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"]]],files:["content.js":"document.documentElement.dataset.extensionProbe='injected';document.documentElement.dataset.captureBridge=String(!!globalThis.webkit?.messageHandlers?.pageglass);"])
            try controller.load(content); try await loadPage()
            try require(try await injected() == nil,"declared host access is not granted automatically")
            let pattern = try WKWebExtension.MatchPattern(string:"http://127.0.0.1/*")
            content.setPermissionStatus(.grantedExplicitly,for:pattern)
            try await loadPage(); try await wait { try await self.injected() == "injected" }
            try require(try await injected() == "injected","approved site content script executes")
            try require(try await view.callAsyncJavaScript("return !!globalThis.webkit?.messageHandlers?.pageglass",arguments:[:],in:nil,contentWorld:.world(name:"dev.pageglass.capture")) as? Bool == true,"capture bridge exists in its own isolated world")
            try require(try await view.evaluateJavaScript("document.documentElement.dataset.captureBridge") as? String == "false","content script cannot reach capture native bridge")
            content.setPermissionStatus(.deniedExplicitly,for:pattern)
            try await loadPage(); try require(try await injected() == nil,"revoking site access stops injection after reload")
            content.setPermissionStatus(.grantedExplicitly,for:pattern)
            try await loadPage(); try await wait { try await self.injected() == "injected" }
            try controller.unload(content)
            try await loadPage(); try require(try await injected() == nil,"disabling extension stops later injection")
            try controller.load(content)
            try await loadPage(); try await wait { try await self.injected() == "injected" }
            try require(try await injected() == "injected","re-enabling extension restores approved content scripts")
            let rules = #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/extension-blocked","resourceTypes":["xmlhttprequest"]}}]"#
            let blocker = try await fixture("request-rules",manifest:["manifest_version":3,"name":"Pageglass rules probe","version":"1.0","permissions":["declarativeNetRequestWithHostAccess"],"host_permissions":["http://127.0.0.1/*"],"declarative_net_request":["rule_resources":[["id":"probe","enabled":true,"path":"rules.json"]]]],files:["rules.json":rules])
            try require(try await request("extension-blocked"),"request succeeds before rule extension is loaded")
            blocker.setPermissionStatus(.grantedExplicitly,for:.declarativeNetRequestWithHostAccess)
            blocker.setPermissionStatus(.grantedExplicitly,for:pattern)
            try controller.load(blocker)
            try await loadPage()
            try require(try await request("extension-allowed"),"request rules preserve unmatched requests")
            try require(try await !request("extension-blocked"),"declared request rule blocks matching fetch")
            blocker.setPermissionStatus(.deniedExplicitly,for:pattern)
            try require(!blocker.hasAccess(to:base),"request-rule context reports revoked host access")
            try await loadPage()
            let directRevokeRestoresRequest = try await request("extension-blocked")
            if !directRevokeRestoresRequest { failures.append("DNR site revocation leaves matching requests blocked") }
            try controller.unload(blocker)
            try await wait { try await self.request("extension-blocked") }
            try require(try await request("extension-blocked"),"unloaded rules no longer block requests")
            try controller.load(blocker); try await loadPage()
            if try await !request("extension-blocked") { failures.append("Reloaded DNR rules still block a denied site") }
            else { checks.append("reloaded rules respect previously revoked site access") }
            try controller.unload(blocker)
            try require(contexts.allSatisfy { !$0.hasAccessToPrivateData },"all probe extensions deny private data")
            try require(contexts.allSatisfy { !$0.hasAccess(to:URL(fileURLWithPath:"/tmp/capture.json")) },"local-file access is never granted")
            for context in contexts where context.isLoaded { try controller.unload(context) }
            try require(controller.extensionContexts.isEmpty,"all extension contexts unload")
            await cleanup()
            try report(status:failures.isEmpty ? "passed" : "failed",error:failures.isEmpty ? nil : failures.joined(separator:"; "))
            print("EXTENSION PROBE \(failures.isEmpty ? "PASS" : "FAIL") \(checks.count) passed, \(failures.count) failed")
            if failures.isEmpty { NSApp.terminate(nil) } else { exit(1) }
        } catch {
            await cleanup()
            try? report(status:"failed",error:error.localizedDescription)
            print("EXTENSION PROBE FAIL \(error)"); exit(1)
        }
    }
    func cleanup() async {
        popup?.close(); popup = nil
        for context in contexts where context.isLoaded { try? controller.unload(context) }
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes:types)
        await controller.removeData(ofTypes:types,from:records)
        await websiteDataStore.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast)
        view.configuration.userContentController.removeScriptMessageHandler(forName:"pageglass",contentWorld:.world(name:"dev.pageglass.capture"))
    }
    func report(status:String,error:String?) throws {
        try JSONSerialization.data(withJSONObject:["status":status,"checks":checks,"failedChecks":failures,"error":error as Any? ?? NSNull(),"system":ProcessInfo.processInfo.operatingSystemVersionString,"scope":"Three owned fixtures; API integration only, not browser UI or real extension compatibility acceptance"],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
    }
    func webExtensionController(_ controller:WKWebExtensionController,openWindowsFor context:WKWebExtensionContext)->[any WKWebExtensionWindow] { [self] }
    func webExtensionController(_ controller:WKWebExtensionController,focusedWindowFor context:WKWebExtensionContext)->(any WKWebExtensionWindow)? { self }
    func webExtensionController(_ controller:WKWebExtensionController,presentActionPopup action:WKWebExtension.Action,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        print("Present popup delegate invoked")
        popup = action.popupPopover; popup?.show(relativeTo:NSRect(x:900,y:650,width:1,height:1),of:view,preferredEdge:.minY); completionHandler(nil)
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {}
    func tabs(for context:WKWebExtensionContext)->[any WKWebExtensionTab] { [self] }
    func activeTab(for context:WKWebExtensionContext)->(any WKWebExtensionTab)? { self }
    func isPrivate(for context:WKWebExtensionContext)->Bool { false }
    func window(for context:WKWebExtensionContext)->(any WKWebExtensionWindow)? { self }
    func webView(for context:WKWebExtensionContext)->WKWebView? { view }
    func url(for context:WKWebExtensionContext)->URL? { view.url }
    func title(for context:WKWebExtensionContext)->String? { view.title }
    func indexInWindow(for context:WKWebExtensionContext)->Int { 0 }
    func shouldGrantPermissionsOnUserGesture(for context:WKWebExtensionContext)->Bool { false }
    func shouldBypassPermissions(for context:WKWebExtensionContext)->Bool { false }
}

if #available(macOS 15.4, *) {
    setbuf(stdout,nil)
    let args = CommandLine.arguments
    guard args.count == 3,let base = URL(string:args[2]),base.scheme == "http",base.host == "127.0.0.1" else { fputs("Usage: probe /tmp/output http://127.0.0.1:port\n",stderr); exit(2) }
    let output = URL(fileURLWithPath:args[1],isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
    guard output.path.hasPrefix("/private/tmp/") else { exit(2) }
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    MainActor.assumeIsolated { let probe = Probe(output:output,base:base); app.delegate = probe; app.run() }
} else { fputs("WebExtension probe requires macOS 15.4+\n",stderr); exit(2) }
