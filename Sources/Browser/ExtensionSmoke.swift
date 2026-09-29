import AppKit
import WebKit

/// Owned fixtures exercise the production host; third-party compatibility and physical UI are separate gates.
@available(macOS 15.4, *)
@MainActor
enum ExtensionSmoke {
    static func runStandalone(base:URL,output:URL) async {
        do {
            let checks = try await run(base:base,output:output)
            try JSONSerialization.data(withJSONObject:["passed":checks,"status":"passed"],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
            print("EXTENSION HOST PASS \(checks.count) \(output.path)")
            CaptureClipboard.finishTesting(); NSApp.terminate(nil)
        } catch { print("EXTENSION HOST FAIL \(error)"); CaptureClipboard.finishTesting(); exit(1) }
    }
    static func run(base:URL,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ label:String) throws {
            guard condition else { throw CaptureService.Failure.message(label) }
            checks.append("extension host: "+label)
        }
        func wait(_ label:String,_ predicate:() async throws->Bool) async throws {
            for _ in 0..<120 { if (try? await predicate()) == true { return }; try await Task.sleep(for:.milliseconds(50)) }
            throw CaptureService.Failure.message("extension timeout: "+label)
        }
        func script(_ view:WKWebView,_ source:String) async throws->Any? {
            try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(source,arguments:[:],in:nil,in:.page) { continuation.resume(with:$0) }
            }
        }
        let root = output.appendingPathComponent("extension-host"),source = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let files:[String:String] = [
            "popup.html":"<!doctype html><meta charset=utf-8><title>Owned extension</title><style>body{width:300px;padding:20px;font:14px system-ui}</style><h1>Owned extension</h1><output>Loading</output><script src=popup.js></script>",
            "popup.js":"(async()=>{try{document.body.dataset.phase='storage-read';const s=await browser.storage.local.get('count');const count=(s.count||0)+1;document.body.dataset.phase='storage-write';await browser.storage.local.set({count});document.body.dataset.phase='worker-message';const reply=await browser.runtime.sendMessage({ping:true});document.body.dataset.phase='ready';document.querySelector('output').textContent=JSON.stringify({count,reply,bridge:!!globalThis.webkit?.messageHandlers?.pageglass,execute:typeof browser.scripting?.executeScript});document.body.dataset.ready='true';}catch(e){document.querySelector('output').textContent=String(e);document.body.dataset.ready='error';}})();",
            "options.html":"<!doctype html><title>Owned settings</title><p>Extension options</p>",
            "worker.js":"const events=[];for(const [name,event] of [['created',browser.tabs.onCreated],['removed',browser.tabs.onRemoved],['activated',browser.tabs.onActivated],['updated',browser.tabs.onUpdated],['moved',browser.tabs.onMoved]])event.addListener(()=>{events.push(name)});browser.runtime.onMessage.addListener((m,s,reply)=>{reply({pong:m.ping===true,events})});",
            "content.js":"document.documentElement.dataset.pageglassExtension='1';document.documentElement.dataset.extensionBridge=String(!!globalThis.webkit?.messageHandlers?.pageglass);"
        ]
        for (name,text) in files { try text.write(to:source.appendingPathComponent(name),atomically:true,encoding:.utf8) }
        func writeManifest(_ version:String) throws {
            let object:[String:Any] = ["manifest_version":3,"name":"Pageglass owned host fixture","description":"Production extension host validation","version":version,"permissions":["storage","tabs"],"host_permissions":["http://127.0.0.1/*"],"action":["default_popup":"popup.html"],"options_ui":["page":"options.html"],"background":["service_worker":"worker.js"],"content_scripts":[["matches":["http://127.0.0.1/*"],"js":["content.js"]]]]
            try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:source.appendingPathComponent("manifest.json"))
        }
        try writeManifest("1.0")
        let dataID = UUID(),dataStore = WKWebsiteDataStore(forIdentifier:dataID),profile = root.appendingPathComponent("profile")
        let store = BrowserStore(directory:profile)
        var runtime = store.extensions(dataStore:dataStore)
        var browser = BrowserWindow(store:store,dataStore:dataStore)
        let privateWindow = BrowserWindow(privateBrowsing:true,store:store)
        let page = base.appendingPathComponent("browser-test"),site = ExtensionRuntime.sitePattern(page)!
        browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil)
        func load() async throws {
            browser.load(page)
            do { try await wait("fixture navigation") {
                guard !browser.webView.isLoading,browser.webView.url == page else { return false }
                return try await browser.webView.evaluateJavaScript("document.readyState") as? String == "complete"
            } } catch { throw CaptureService.Failure.message("\(error.localizedDescription); actual=\(browser.webView.url?.absoluteString ?? "nil"); expected=\(page.absoluteString); loading=\(browser.webView.isLoading); title=\(browser.webView.title ?? "nil"); failure=\(String(describing:browser.tabs[browser.activeIndex].failure))") }
        }
        func popup(_ context:WKWebExtensionContext) async throws->WKWebView {
            // A real toolbar click activates the app; closing a test-only options window can return focus to another app.
            NSApp.activate(ignoringOtherApps:true)
            browser.window?.makeKeyAndOrderFront(nil)
            try await wait("browser focus for extension action") { NSApp.isActive && browser.window?.isKeyWindow == true }
            let tab = browser.tabs[browser.activeIndex]
            let id = runtime.contexts.first(where:{$0.value === context})?.key
            if let id,let button = browser.extensionActionButtons[id] { button.performClick(nil) }
            else { context.performAction(for:tab.extensionVisible ? tab : nil) }
            do { try await wait("popup presentation") { runtime.popup?.isShown == true } }
            catch {
                let action = context.action(for:tab.extensionVisible ? tab : nil)
                let diagnostic:[String:Any] = ["stageChecks":checks,"applicationActive":NSApp.isActive,"windowVisible":browser.window?.isVisible ?? false,"windowKey":browser.window?.isKeyWindow ?? false,"buttonHidden":browser.extensionButton.isHidden,"buttonBounds":NSStringFromRect(browser.extensionButton.bounds),"contextLoaded":context.isLoaded,"tabVisible":tab.extensionVisible,"hostPopoverExists":runtime.popup != nil,"hostPopoverShown":runtime.popup?.isShown ?? false,"actionPresentsPopup":action?.presentsPopup ?? false,"popupLoading":action?.popupWebView?.isLoading ?? false,"popupURL":action?.popupWebView?.url?.absoluteString ?? "nil","extensionErrors":context.webExtension.errors.map{$0.localizedDescription}]
                try? JSONSerialization.data(withJSONObject:diagnostic,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("popup-presentation-failure.json"))
                throw error
            }
            guard let view = context.action(for:tab.extensionVisible ? tab : nil)?.popupWebView else { throw CaptureService.Failure.message("popup view missing") }
            do { try await wait("popup script") { try await view.evaluateJavaScript("document.body?.dataset.ready") as? String == "true" } }
            catch {
                let message = try? await view.evaluateJavaScript("JSON.stringify({output:document.querySelector('output')?.textContent,phase:document.body?.dataset.phase,loading:document.readyState})")
                throw CaptureService.Failure.message("popup script failed: \(String(describing:message)); url=\(view.url?.absoluteString ?? "nil")")
            }
            return view
        }
        func cleanup() async {
            browser.window?.close(); privateWindow.window?.close()
            for context in runtime.contexts.values where context.isLoaded { try? runtime.controller.unload(context) }
            let types = WKWebExtensionController.allExtensionDataTypes
            let records = await runtime.controller.dataRecords(ofTypes:types)
            await runtime.controller.removeData(ofTypes:types,from:records)
            await dataStore.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier:dataID)
        }
        do {
            // End all popup/context references before creating another host for the same persistent identity.
            func exerciseBeforeRestore() async throws->UUID {
                try await wait("initial browser document") { !browser.webView.isLoading && browser.webView.url != nil }
                try await load()
                try await runtime.install(ExtensionPackage.prepare(source:source,in:runtime.repository.staging))
                let record = runtime.repository.state.items[0],id = record.id
                guard var context = runtime.contexts[id] else { throw CaptureService.Failure.message("installed context missing") }
                try require(context.isLoaded,"reviewed owned package loads")
                try require(!context.hasAccess(to:page),"installation does not grant declared sites")
                try require(browser.extensionActionButtons.isEmpty,"installation does not add an unrequested toolbar action")
                try runtime.setToolbarVisible(true,id:id)
                try require(browser.extensionActionButtons[id] != nil && !context.hasAccess(to:page),"toolbar preference reveals the action without granting site access")
                let originalFrame = browser.window!.frame
                for width:CGFloat in [820,900] {
                    browser.window?.setFrame(NSRect(x:originalFrame.minX,y:originalFrame.minY,width:width,height:originalFrame.height),display:true)
                    browser.updateToolbarLayout(); browser.window?.contentView?.layoutSubtreeIfNeeded()
                    try require((browser.extensionActionButtons[id] != nil) == (width >= 900) && browser.address.bounds.width >= 180,"toolbar action adapts at \(Int(width)) pt without compressing the address field")
                }
                browser.window?.setFrame(originalFrame,display:true); browser.updateToolbarLayout()
                try await load()
                try require(try await browser.webView.evaluateJavaScript("document.documentElement.dataset.pageglassExtension || ''") as? String == "","unapproved site has no content injection")
                try runtime.setSite(site,allowed:true,id:id); try await load()
                try await wait("granted content script") { try await browser.webView.evaluateJavaScript("document.documentElement.dataset.pageglassExtension") as? String == "1" }
                try require(try await browser.webView.evaluateJavaScript("document.documentElement.dataset.extensionBridge") as? String == "false","content script cannot reach native capture bridge")
                let first = try await popup(context)
                let result = try await first.evaluateJavaScript("JSON.parse(document.querySelector('output').textContent)") as? [String:Any] ?? [:]
                try require(result["count"] as? Int == 1,"real action popup reads and writes storage")
                try require((result["reply"] as? [String:Any])?["pong"] as? Bool == true,"popup reaches MV3 worker")
                try require(result["bridge"] as? Bool == false && result["execute"] as? String == "undefined","popup excludes capture bridge and programmatic injection")
                _ = try await script(first,"await browser.action.setTitle({title:'Toolbar action updated'});await browser.action.disable();return true")
                try await wait("action change reaches toolbar") { browser.extensionActionButtons[id]?.toolTip?.contains("Toolbar action updated") == true && browser.extensionActionButtons[id]?.isEnabled == false }
                try require(browser.extensionActionButtons[id]?.isEnabled == false,"action API updates native toolbar title and disabled state")
                _ = try await script(first,"await browser.action.enable();return true")
                try await wait("action enabled again") { browser.extensionActionButtons[id]?.isEnabled == true }
                let originalActive = browser.tabs[browser.activeIndex]
                let created = try await script(first,"const tabs=await browser.tabs.query({});const tab=await browser.tabs.create({url:tabs[0].url,active:false,index:0});globalThis.createdTestTab=tab.id;return {id:tab.id,index:tab.index};") as? [String:Any] ?? [:]
                try require(created["index"] as? Int == 0 && browser.tabs.count == 2 && browser.tabs[browser.activeIndex] === originalActive,"tabs create respects requested index without stealing activation")
                _ = try await script(first,"await browser.tabs.remove(globalThis.createdTestTab);return true")
                try require(browser.tabs.count == 1 && browser.tabs[0] === originalActive,"tabs remove closes only the requested background tab")
                runtime.closeViews(id)
                try runtime.showOptions(id)
                try await wait("options page") { NSApp.windows.compactMap { $0.contentView as? WKWebView }.contains { $0.url?.lastPathComponent == "options.html" && !$0.isLoading } }
                let options = NSApp.windows.compactMap { $0.contentView as? WKWebView }.first { $0.url?.lastPathComponent == "options.html" }
                if let options {
                    let bridge = try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Any,Error>) in
                        options.evaluateJavaScript("!!globalThis.webkit?.messageHandlers?.pageglass",in:nil,in:CaptureService.world) { continuation.resume(with:$0) }
                    }
                    let sources = options.configuration.userContentController.userScripts.map { $0.source }
                    let diagnostic:[String:Any] = ["captureBridge":bridge,"scriptPrefixes":sources.map { String($0.prefix(180)) },"hasCaptureSource":sources.contains(CaptureService.script),"hasRecorderSource":sources.contains(InteractionRecording.script)]
                    try JSONSerialization.data(withJSONObject:diagnostic,options:.prettyPrinted).write(to:root.appendingPathComponent("options-isolation.json"))
                    try require(bridge as? Bool == false && !sources.contains(CaptureService.script) && !sources.contains(InteractionRecording.script),"options use a separate view without capture scripts or native bridge")
                } else { throw CaptureService.Failure.message("options page not found") }
                runtime.closeViews(id)
                try require(privateWindow.webView.configuration.webExtensionController == nil && privateWindow.extensions == nil,"private windows have no extension controller")
                try require(privateWindow.extensionActionButtons.isEmpty && privateWindow.extensionActionBar.isHidden,"private windows do not expose toolbar extension actions")
                browser.openTab(page.appendingPathComponent("second"),inBackground:true)
                let extra = browser.tabs.last!,original = browser.tabs[0]
                browser.moveTab(extra.id,relativeTo:original.id)
                browser.activate(0)
                try await wait("second tab settles") { !browser.webView.isLoading }
                browser.close(at:0)
                try await load()
                let eventsView = try await popup(context)
                let eventValue = try await script(eventsView,"return await browser.runtime.sendMessage({ping:true})") as? [String:Any] ?? [:]
                let events = Set(eventValue["events"] as? [String] ?? [])
                try require(Set(["created","removed","activated","updated","moved"]).isSubset(of:events),"worker receives tab lifecycle and property events")
                runtime.closeViews(id)
                browser.newTab()
                try await wait("internal page") { browser.webView.url?.isFileURL == true && !browser.webView.isLoading }
                let internalView = try await popup(context)
                let queryJSON = try await script(internalView,"return JSON.stringify(await browser.tabs.query({}))") as? String ?? "null"
                let queried = try JSONSerialization.jsonObject(with:Data(queryJSON.utf8),options:.fragmentsAllowed) as? [[String:Any]] ?? []
                try JSONSerialization.data(withJSONObject:["queried":queried,"queryJSON":queryJSON,"runtimeWindows":runtime.windows.allObjects.count,"contextWindows":context.openWindows.count,"contextTabs":context.openTabs.count,"delegateTabs":browser.tabs(for:context).count,"hostTabs":browser.tabs.map { ["visible":$0.extensionVisible,"url":($0.webView?.url ?? $0.url)?.absoluteString ?? "nil"] },"privateHasController":privateWindow.webView.configuration.webExtensionController != nil],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("tab-isolation.json"))
                try require(queried.isEmpty,"protected active page hides its window from extension tab queries")
                runtime.closeViews(id); browser.activate(0)
                let visibleView = try await popup(context)
                let visibleTabs = try await script(visibleView,"return await browser.tabs.query({})") as? [[String:Any]] ?? []
                try require(visibleTabs.count == 1 && visibleTabs.allSatisfy { ($0["url"] as? String)?.hasPrefix("http://127.0.0.1") == true },"normal active page restores tab queries while excluding protected and private tabs")
                runtime.closeViews(id); browser.close(at:1)
                try runtime.setSite(site,allowed:false,id:id); try await load()
                let revokedDOM = try await browser.webView.evaluateJavaScript("document.documentElement.dataset.pageglassExtension || ''") as? String
                try require(!context.hasAccess(to:page) && revokedDOM == "","revocation removes future injection after reload")
                try runtime.setSite(site,allowed:true,id:id)
                try await runtime.setEnabled(false,id:id); try await load()
                let disabledDOM = try await browser.webView.evaluateJavaScript("document.documentElement.dataset.pageglassExtension || ''") as? String
                try require(!context.isLoaded && disabledDOM == "","disable unloads context and prevents injection")
                try require(browser.extensionActionButtons[id] == nil && runtime.repository.state.items[0].toolbarVisible == true,"disabling removes the toolbar action while retaining its preference")
                try await runtime.setEnabled(true,id:id)
                context = runtime.contexts[id]!
                let reenabled = try await popup(context)
                try require((try await reenabled.evaluateJavaScript("JSON.parse(document.querySelector('output').textContent).count") as? Int ?? 0) >= 2,"storage survives disable and reenable")
                runtime.closeViews(id)
                try writeManifest("invalid version")
                do { try await runtime.install(ExtensionPackage.prepare(source:source,in:runtime.repository.staging),replacing:id); throw CaptureService.Failure.message("invalid update unexpectedly loaded") }
                catch { try require(runtime.repository.state.items[0].version == "1.0" && context.isLoaded,"invalid update preserves previous version and running context") }
                try writeManifest("2.0")
                try "document.documentElement.dataset.pageglassExtension='2';".write(to:source.appendingPathComponent("content.js"),atomically:true,encoding:.utf8)
                // Make an owned registry path unwritable as a file, then restore it; exercise rollback after candidate load.
                do {
                    let file = runtime.repository.root.appendingPathComponent("extensions.json"),bytes = try Data(contentsOf:file)
                    try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
                    defer { try? FileManager.default.removeItem(at:file); try? bytes.write(to:file,options:.atomic) }
                    do { try await runtime.install(ExtensionPackage.prepare(source:source,in:runtime.repository.staging),replacing:id); throw CaptureService.Failure.message("registry fault unexpectedly saved") }
                    catch { try require(runtime.repository.state.items[0].version == "1.0" && context.isLoaded,"failed registry save reloads previous running version") }
                }
                try await runtime.install(ExtensionPackage.prepare(source:source,in:runtime.repository.staging),replacing:id)
                context = runtime.contexts[id]!
                try await load()
                try await wait("updated content") { try await browser.webView.evaluateJavaScript("document.documentElement.dataset.pageglassExtension") as? String == "2" }
                try require(runtime.repository.state.items[0].id == id && context.hasAccess(to:page),"update preserves identity and reviewed site grants")
                try require(browser.extensionActionButtons[id] != nil && runtime.repository.state.items[0].toolbarVisible == true,"updating preserves the optional toolbar action")
                browser.window?.close(); try runtime.controller.unload(context)
                return id
            }
            let id = try await exerciseBeforeRestore()
            // Release the old profile's host before constructing another controller with its persistent identifier.
            store.extensionRuntime = nil
            let restartedStore = BrowserStore(directory:profile)
            runtime = restartedStore.extensions(dataStore:dataStore); await runtime.restore()
            browser = BrowserWindow(store:restartedStore,dataStore:dataStore); browser.showWindow(nil)
            try await wait("restored browser document") { !browser.webView.isLoading && browser.webView.url != nil }
            guard let restoredContext = runtime.contexts[id] else { throw CaptureService.Failure.message("restore failed: \(runtime.errors)") }
            let context = restoredContext
            try await load()
            let restored = try await popup(context)
            let restoredCount = try await restored.evaluateJavaScript("JSON.parse(document.querySelector('output').textContent).count") as? Int ?? 0
            try require(runtime.errors.isEmpty && runtime.repository.state.items[0].version == "2.0" && restoredCount >= 3,"new host restores version permissions and persistent storage")
            try require(browser.extensionActionButtons[id] != nil,"new host restores the saved toolbar preference")
            runtime.closeViews(id)
            try await runtime.remove(id:id,includingData:false)
            try require(runtime.contexts[id] == nil && runtime.repository.state.items[0].package == nil,"remove program keeps an explicit data-only record")
            try await runtime.install(ExtensionPackage.prepare(source:source,in:runtime.repository.staging),replacing:id)
            let retained = try await popup(runtime.contexts[id]!)
            try require((try await retained.evaluateJavaScript("JSON.parse(document.querySelector('output').textContent).count") as? Int ?? 0) >= 4,"reinstall can reuse explicitly retained extension data")
            try runtime.setToolbarVisible(false,id:id)
            try require(browser.extensionActionButtons[id] == nil && runtime.contexts[id]?.isLoaded == true,"hiding toolbar action leaves the extension enabled")
            runtime.closeViews(id)
            let contentSource = root.appendingPathComponent("content-only-fixture")
            try FileManager.default.createDirectory(at:contentSource,withIntermediateDirectories:true)
            let contentManifest:[String:Any] = ["manifest_version":3,"name":"Content-only fixture","description":"Owned static content extension without an action","version":"1.0","content_scripts":[["matches":["http://127.0.0.1/*"],"js":["content.js"]]]]
            try JSONSerialization.data(withJSONObject:contentManifest).write(to:contentSource.appendingPathComponent("manifest.json"))
            try "document.documentElement.dataset.contentOnly='1';".write(to:contentSource.appendingPathComponent("content.js"),atomically:true,encoding:.utf8)
            let manager = ExtensionManagementController(browser:browser); browser.extensionManager = manager
            manager.selectExtension(id)
            try await manager.installReviewed(ExtensionPackage.prepare(source:contentSource,in:runtime.repository.staging))
            guard let contentID = runtime.repository.state.items.first(where:{$0.name == "Content-only fixture"})?.id else { throw CaptureService.Failure.message("content-only install missing") }
            try require(manager.selected?.id == contentID,"install selects the newly installed extension instead of the previous row")
            try runtime.setToolbarVisible(true,id:contentID)
            try require(runtime.action(contentID,browser:browser) == nil && browser.extensionActionButtons[contentID] == nil,"content-only extension has no synthetic runnable toolbar action")
            let contentItem = browser.extensionMenu().items.first { $0.representedObject as? String == contentID.uuidString }
            guard let contentItem,let menuAction = contentItem.action else { throw CaptureService.Failure.message("content-only management entry missing") }
            manager.selectExtension(id)
            _ = NSApp.sendAction(menuAction,to:contentItem.target,from:contentItem)
            try require(contentItem.title.hasSuffix("网站权限…") && manager.selected?.id == contentID && runtime.popup == nil,"content-only menu opens the matching permission details without a fake popup")
            manager.close()
            try runtime.setSite(site,allowed:true,id:contentID); try await load()
            try await wait("content-only injection") { try await browser.webView.evaluateJavaScript("document.documentElement.dataset.contentOnly") as? String == "1" }
            try require(runtime.contexts[contentID]?.hasAccess(to:page) == true,"content-only extension still runs its granted static script without an action")
            try await runtime.remove(id:contentID,includingData:true)
            runtime.closeViews(id); try await runtime.remove(id:id,includingData:true)
            try require(runtime.repository.state.items.isEmpty && runtime.contexts.isEmpty,"remove including data clears installed record and context")
            await cleanup(); return checks
        } catch {
            let report:[String:Any] = ["passed":checks,"error":error.localizedDescription]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("failure.json"))
            await cleanup(); throw error
        }
    }
}
