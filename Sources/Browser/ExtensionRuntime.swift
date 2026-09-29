import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor
extension BrowserStore {
    func extensions(dataStore:WKWebsiteDataStore)->ExtensionRuntime {
        if let existing = extensionRuntime as? ExtensionRuntime { return existing }
        let runtime = ExtensionRuntime(directory:directory,dataStore:dataStore); extensionRuntime = runtime; return runtime
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionRuntime:NSObject,WKWebExtensionControllerDelegate {
    static let changed = Notification.Name("PageglassExtensionsChanged")
    let repository:ExtensionRepository, controller:WKWebExtensionController
    let windows = NSHashTable<BrowserWindow>.weakObjects()
    var tabSnapshots:[UUID:[ExtensionTabSnapshot]] = [:]
    var activeTabs:[UUID:BrowserTab] = [:]
    var visibleWindows:Set<UUID> = []
    private(set) var contexts:[UUID:WKWebExtensionContext] = [:]
    private(set) var errors:[UUID:String] = [:]
    private(set) var busy = false
    private var restored = false
    private(set) var popup:NSPopover?
    private var options:[UUID:ExtensionOptionsController] = [:]
    init(directory:URL,dataStore:WKWebsiteDataStore) {
        repository = ExtensionRepository(directory:directory)
        let config = WKWebExtensionController.Configuration(identifier:repository.state.controllerID)
        config.defaultWebsiteDataStore = dataStore
        controller = WKWebExtensionController(configuration:config)
        super.init(); controller.delegate = self
    }
    func changed() {
        for browser in windows.allObjects { browser.updateExtensionActions() }
        NotificationCenter.default.post(name:Self.changed,object:self)
    }
    func setToolbarVisible(_ visible:Bool,id:UUID) throws {
        try begin(); defer { end() }
        guard var record = repository.state.items.first(where:{$0.id == id}),record.package != nil else { throw ExtensionPackage.Failure(message:"扩展程序已移除") }
        record.toolbarVisible = visible; try repository.replace(record)
    }
    func begin() throws {
        guard !busy,repository.readError == nil else { throw ExtensionPackage.Failure(message:repository.readError ?? "扩展操作正在进行，请稍候") }
        guard !windows.allObjects.contains(where:{$0.capturing}) else { throw ExtensionPackage.Failure(message:"请等待捕获结束后再更改扩展") }
        busy = true; changed()
    }
    func end() { busy = false; changed() }
    func restore() async {
        guard !restored else { return }
        do {
            try begin(); restored = true; defer { end() }
            for record in repository.state.items where record.enabled && record.package != nil {
                do { let context = try await makeContext(record); try controller.load(context); contexts[record.id] = context }
                catch { errors[record.id] = error.localizedDescription }
            }
        } catch { changed() }
    }
    func makeContext(_ record:InstalledExtension) async throws->WKWebExtensionContext {
        guard let directory = repository.directory(for:record) else { throw ExtensionPackage.Failure(message:"扩展程序已移除，请重新导入") }
        let checked = try await Task.detached(priority:.userInitiated) { try ExtensionPackage.inspect(directory,sourceName:record.sourceName) }.value
        guard checked.digest == record.digest else { throw ExtensionPackage.Failure(message:"扩展文件发生变化，请通过更新重新导入") }
        let extensionObject = try await WKWebExtension(resourceBaseURL:directory)
        guard extensionObject.errors.isEmpty else { throw ExtensionPackage.Failure(message:extensionObject.errors.map(\.localizedDescription).joined(separator:"；")) }
        let context = WKWebExtensionContext(for:extensionObject)
        context.uniqueIdentifier = record.id.uuidString.lowercased(); context.baseURL = URL(string:"webkit-extension://\(record.id.uuidString.lowercased())/")!
        context.hasAccessToPrivateData = false; context.isInspectable = true
        context.unsupportedAPIs = ["browser.scripting.executeScript","browser.scripting.registerContentScripts","browser.scripting.updateContentScripts","browser.tabs.executeScript","browser.runtime.sendNativeMessage","browser.runtime.connectNative"]
        for permission in extensionObject.requestedPermissions { context.setPermissionStatus(.grantedExplicitly,for:permission) }
        for (site,allowed) in record.sites {
            guard Self.sitePattern(URL(string:site)) == site else { throw ExtensionPackage.Failure(message:"已保存的网站授权格式无效，请移除此扩展后重新安装") }
            let pattern = try WKWebExtension.MatchPattern(string:site)
            context.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly,for:pattern)
        }
        return context
    }
    /// Called only after the install/update review; website grants are retained separately.
    @discardableResult
    func install(_ prepared:ExtensionPackage,replacing id:UUID? = nil) async throws->UUID {
        try begin(); defer { end() }
        let old = repository.state.items.first { $0.id == id }
        guard id == nil || old != nil else { throw ExtensionPackage.Failure(message:"待更新的扩展已移除，请重新选择") }
        guard id != nil || !repository.state.items.contains(where:{$0.package != nil && $0.digest == prepared.digest}) else { throw ExtensionPackage.Failure(message:"这个扩展版本已导入，请选择已有扩展进行更新") }
        let record = repository.adopt(prepared,replacing:old)
        let destination = repository.directory(for:record)!
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.moveItem(at:prepared.directory,to:destination)
        let previous = old.flatMap { contexts[$0.id] }
        var candidate:WKWebExtensionContext?
        do {
            let context = try await makeContext(record); candidate = context
            if let previous { try controller.unload(previous); closeViews(record.id) }
            try controller.load(context)
            try repository.replace(record)
            contexts[record.id] = context; errors[record.id] = nil
        } catch {
            let failure = error
            var rollbackErrors:[String] = []
            if let candidate,candidate.isLoaded { do { try controller.unload(candidate) } catch { rollbackErrors.append(error.localizedDescription) } }
            if let previous,!previous.isLoaded { do { try controller.load(previous) } catch { rollbackErrors.append(error.localizedDescription); contexts[record.id] = nil } }
            if !rollbackErrors.isEmpty {
                errors[record.id] = "更新失败，恢复旧版本也失败："+rollbackErrors.joined(separator:"；")
                throw ExtensionPackage.Failure(message:failure.localizedDescription+"；"+errors[record.id]!)
            }
            try? FileManager.default.removeItem(at:destination)
            throw failure
        }
        if let oldDirectory = old.flatMap(repository.directory(for:)) { try? FileManager.default.trashItem(at:oldDirectory,resultingItemURL:nil) }
        return record.id
    }
    func setEnabled(_ enabled:Bool,id:UUID) async throws {
        try begin(); defer { end() }
        guard var record = repository.state.items.first(where:{$0.id == id}),record.package != nil else { throw ExtensionPackage.Failure(message:"扩展程序已移除") }
        let previous = contexts[id]
        do {
            if enabled {
                if previous?.isLoaded != true { let context = try await makeContext(record); try controller.load(context); contexts[id] = context }
            } else if let previous { try controller.unload(previous); closeViews(id); contexts[id] = nil }
            record.enabled = enabled; try repository.replace(record); errors[id] = nil
        } catch {
            if enabled,previous == nil,let added = contexts.removeValue(forKey:id) { try? controller.unload(added) }
            if !enabled,let previous,!previous.isLoaded { try? controller.load(previous); contexts[id] = previous }
            errors[id] = error.localizedDescription; throw error
        }
    }
    func remove(id:UUID,includingData:Bool) async throws {
        try begin(); defer { end() }
        guard var record = repository.state.items.first(where:{$0.id == id}) else { return }
        let old = record
        record.enabled = false; try repository.replace(record)
        if let context = contexts[id] { try controller.unload(context); contexts[id] = nil }
        closeViews(id)
        if let directory = repository.directory(for:record),FileManager.default.fileExists(atPath:directory.path) { try FileManager.default.trashItem(at:directory,resultingItemURL:nil) }
        record.package = nil
        if includingData {
            let types = WKWebExtensionController.allExtensionDataTypes
            let records = await controller.dataRecords(ofTypes:types).filter { $0.uniqueIdentifier == old.id.uuidString.lowercased() }
            await controller.removeData(ofTypes:types,from:records)
            try repository.save(repository.state.items.filter { $0.id != id })
        } else { try repository.replace(record) }
        errors[id] = nil
    }
    func closeViews(_ id:UUID) { popup?.close(); popup = nil; options.removeValue(forKey:id)?.close() }
    static func sitePattern(_ url:URL?)->String? {
        guard let url,let scheme = url.scheme, ["http","https"].contains(scheme),let host = url.host,!host.isEmpty,!host.contains("*"),!host.contains(":") else { return nil }
        return "\(scheme)://\(host)/*"
    }
    func setSite(_ site:String,allowed:Bool,id:UUID) throws {
        guard !busy,!windows.allObjects.contains(where:{$0.capturing}) else { throw ExtensionPackage.Failure(message:"请等待捕获或当前扩展操作结束") }
        guard let url = URL(string:site),Self.sitePattern(url) == site,let index = repository.state.items.firstIndex(where:{$0.id == id}) else { throw ExtensionPackage.Failure(message:"仅支持按 HTTP / HTTPS 网站授权") }
        let pattern = try WKWebExtension.MatchPattern(string:site)
        var record = repository.state.items[index]; record.sites[site] = allowed; try repository.replace(record)
        if let context = contexts[id] {
            context.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly,for:pattern)
            for window in windows.allObjects { for tab in window.tabs { context.clearUserGesture(in:tab) } }
        }
        changed()
    }
    func grantCurrentSite(_ id:UUID,browser:BrowserWindow)->Bool {
        guard !browser.privateBrowsing,let context = contexts[id],let url = browser.activeWebView?.url,let site = Self.sitePattern(url) else { return false }
        if context.hasAccess(to:url) { return true }
        let alert = NSAlert(); alert.messageText = "允许“\(context.webExtension.displayName ?? "扩展")”访问此网站？"
        alert.informativeText = "\(site)\n扩展可读取和修改该网站的页面内容。仅授权此网站；可在扩展管理中撤销。"
        alert.addButton(withTitle:"不允许"); alert.addButton(withTitle:"允许此网站")
        let allowed = alert.runModal() == .alertSecondButtonReturn
        do { try setSite(site,allowed:allowed,id:id) } catch { browser.status.show(error.localizedDescription,persistent:true); return false }
        return allowed
    }
    func performAction(_ id:UUID,browser:BrowserWindow) {
        guard !busy,!browser.privateBrowsing,!browser.capturing,let context = contexts[id],context.isLoaded else { return }
        guard action(id,browser:browser)?.isEnabled == true else { return }
        if let url = browser.activeWebView?.url,context.webExtension.allRequestedMatchPatterns.contains(where:{$0.matches(url)}),!context.hasAccess(to:url) {
            _ = grantCurrentSite(id,browser:browser)
        }
        context.performAction(for:browser.tabs.indices.contains(browser.activeIndex) && browser.tabs[browser.activeIndex].extensionVisible ? browser.tabs[browser.activeIndex] : nil)
    }
    func showOptions(_ id:UUID) throws {
        guard let context = contexts[id],let url = context.optionsPageURL,let configuration = context.webViewConfiguration else { throw ExtensionPackage.Failure(message:"扩展未启用或没有设置页") }
        options[id]?.close(); let panel = ExtensionOptionsController(url:url,configuration:configuration,title:context.webExtension.displayName ?? "扩展设置")
        options[id] = panel; panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
    }
    func webExtensionController(_ controller:WKWebExtensionController,openWindowsFor context:WKWebExtensionContext)->[any WKWebExtensionWindow] {
        windows.allObjects.filter(\.extensionWindowVisible).sorted { $0.window?.isKeyWindow == true && $1.window?.isKeyWindow != true }
    }
    func webExtensionController(_ controller:WKWebExtensionController,focusedWindowFor context:WKWebExtensionContext)->(any WKWebExtensionWindow)? { windows.allObjects.first { $0.extensionWindowVisible && $0.window?.isKeyWindow == true } }
    func webExtensionController(_ controller:WKWebExtensionController,presentActionPopup action:WKWebExtension.Action,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let browser = windows.allObjects.first(where:{$0.window?.isKeyWindow == true && !$0.privateBrowsing}) ?? windows.allObjects.first(where:{!$0.privateBrowsing}) else { completionHandler(ExtensionPackage.Failure(message:"没有可用的普通浏览器窗口")); return }
        popup?.close(); popup = action.popupPopover
        let button = contexts.first(where:{$0.value === context}).flatMap { browser.extensionActionButtons[$0.key] }
        let anchor = button.flatMap { $0.superview != nil && !browser.extensionActionBar.isHidden ? $0 : nil } ?? browser.extensionButton
        popup?.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxY); completionHandler(nil)
    }
    func webExtensionController(_ controller:WKWebExtensionController,didUpdate action:WKWebExtension.Action,forExtensionContext context:WKWebExtensionContext) {
        for browser in windows.allObjects { browser.updateExtensionActions() }
    }
    func webExtensionController(_ controller:WKWebExtensionController,openOptionsPageFor context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        do { guard let id = contexts.first(where:{$0.value === context})?.key else { throw ExtensionPackage.Failure(message:"扩展已停用") }; try showOptions(id); completionHandler(nil) } catch { completionHandler(error) }
    }
    func webExtensionController(_ controller:WKWebExtensionController,openNewTabUsing configuration:WKWebExtension.TabConfiguration,for context:WKWebExtensionContext,completionHandler:@escaping((any WKWebExtensionTab)?,Error?)->Void) {
        guard let browser = configuration.window as? BrowserWindow ?? windows.allObjects.first(where:{$0.window?.isKeyWindow == true && !$0.privateBrowsing}),!browser.privateBrowsing,!browser.capturing,let url = configuration.url,Self.sitePattern(url) != nil,!configuration.shouldBePinned,!configuration.shouldBeMuted,!configuration.shouldReaderModeBeActive else {
            completionHandler(nil,ExtensionPackage.Failure(message:"扩展只能打开普通 HTTP / HTTPS 标签页")); return
        }
        let selected = browser.tabs.indices.contains(browser.activeIndex) ? browser.tabs[browser.activeIndex] : nil
        let visible = browser.tabs.filter(\.extensionVisible)
        let position = configuration.index < visible.count ? browser.tabs.firstIndex(where:{$0 === visible[configuration.index]}) ?? browser.tabs.count : browser.tabs.count
        let tab = BrowserTab(url:url); tab.owner = browser; browser.tabs.insert(tab,at:position)
        if configuration.shouldBeActive { browser.activate(position) }
        else { browser.activeIndex = selected.flatMap { active in browser.tabs.firstIndex(where:{$0 === active}) } ?? 0; browser.renderTabs(); browser.saveSession() }
        completionHandler(tab,nil)
    }
    func webExtensionController(_ controller:WKWebExtensionController,promptForPermissions permissions:Set<WKWebExtension.Permission>,in tab:(any WKWebExtensionTab)?,for context:WKWebExtensionContext,completionHandler:@escaping(Set<WKWebExtension.Permission>,Date?)->Void) {
        // Optional API permissions require a new reviewed package in this first version.
        completionHandler(permissions.intersection(context.currentPermissions),nil)
    }
    func webExtensionController(_ controller:WKWebExtensionController,promptForPermissionToAccess urls:Set<URL>,in tab:(any WKWebExtensionTab)?,for context:WKWebExtensionContext,completionHandler:@escaping(Set<URL>,Date?)->Void) {
        guard let browser = (tab as? BrowserTab)?.owner,let id = contexts.first(where:{$0.value === context})?.key,let current = browser.activeWebView?.url,urls.allSatisfy({Self.sitePattern($0) == Self.sitePattern(current)}),grantCurrentSite(id,browser:browser) else { completionHandler([],nil); return }
        completionHandler(urls.filter { context.hasAccess(to:$0) },nil)
    }
    func webExtensionController(_ controller:WKWebExtensionController,promptForPermissionMatchPatterns patterns:Set<WKWebExtension.MatchPattern>,in tab:(any WKWebExtensionTab)?,for context:WKWebExtensionContext,completionHandler:@escaping(Set<WKWebExtension.MatchPattern>,Date?)->Void) {
        // Broad host requests cannot silently become an all-site grant.
        completionHandler(patterns.intersection(context.currentPermissionMatchPatterns),nil)
    }
}

final class ExtensionOptionsController:NSWindowController,NSWindowDelegate,WKNavigationDelegate {
    private let origin:URL
    init(url:URL,configuration:WKWebViewConfiguration,title:String) {
        origin = url
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = title; window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self
        let view = WKWebView(frame:.zero,configuration:configuration); view.navigationDelegate = self
        window.contentView = view; window.center(); view.load(URLRequest(url:url))
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func closeTab() { close() }
    func windowWillClose(_ notification:Notification) { let view = window?.contentView as? WKWebView; view?.stopLoading(); view?.navigationDelegate = nil; window?.contentView = NSView() }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        decisionHandler(action.request.url?.scheme == origin.scheme && action.request.url?.host == origin.host ? .allow : .cancel)
    }
}
