import AppKit
import WebKit

@MainActor
enum CaptureAssetSmoke {
    static func run(_ browser:BrowserWindow,base:URL,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ value:Bool,_ label:String) throws { if !value { throw CaptureService.Failure.message(label) }; checks.append(label) }
        func loaded(_ view:WKWebView,url:URL) async throws {
            for _ in 0..<100 { try await Task.sleep(for:.milliseconds(100)); if !view.isLoading,view.url == url { return } }
            throw CaptureService.Failure.message("asset fixture load timeout")
        }
        let url = base.appendingPathComponent("capture-fixture.html")
        let sleeping = BrowserTab(url:base.appendingPathComponent("browser-test"))
        let otherOrigin = BrowserTab(url:URL(string:"https://other.pageglass.test/")!)
        browser.tabs.append(contentsOf:[sleeping,otherOrigin]);browser.renderTabs()
        defer {
            for tab in [sleeping,otherOrigin] { if let index = browser.tabs.firstIndex(where:{$0 === tab}) { browser.close(at:index) } }
        }
        browser.load(url); try await loaded(browser.webView,url:url)
        let view = browser.webView
        // A provisional navigation can still display the previous icon; wait for the new origin too.
        for _ in 0..<80 { if browser.tabs[browser.activeIndex].favicon != nil && browser.favicons.cached(for:url) != nil { break };try await Task.sleep(for:.milliseconds(100)) }
        try require(browser.tabs[browser.activeIndex].favicon != nil,"declared site favicon loads into its actual browser tab")
        try require(browser.favicons.cached(for:url) != nil,"site favicon is reused by bookmark origin")
        let bookmark = PageRecord(title:"Declared icon QA",url:url.absoluteString)
        let bookmarkButton = browser.bookmarkButton(for:bookmark)
        try require(bookmarkButton.image === browser.tabs[browser.activeIndex].favicon,"bookmark button uses the loaded page's declared icon rather than its fallback symbol")
        let otherPath = base.appendingPathComponent("not-visited-bookmark")
        let reusedIcon = await browser.favicons.image(for:otherPath)
        try require(reusedIcon === bookmarkButton.image,"another bookmark path reuses the same origin icon without visiting the page")
        try require(sleeping.favicon === reusedIcon && sleeping.webView == nil,"restored same-origin tab receives its icon without loading a WebView")
        try require(otherOrigin.favicon == nil && otherOrigin.webView == nil,"icon propagation neither changes another origin nor loads its restored tab")
        let ready:Any? = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("await document.fonts.ready; await Promise.all([...document.images].map(i=>i.decode())); return document.querySelector('#raster').naturalWidth",arguments:[:],in:nil,in:CaptureService.world) { continuation.resume(with:$0) }
        }
        try require(ready as? Int == 64,"HTTP capture fixture images and font loaded")
        _ = try await browser.captureService.js(view,"globalThis.__pageglass.selectForTest('#card')")
        let capture = try await browser.captureService.capture(view,mode:"element",destination:output) { _ in }
        let manifest = capture.metadata["assetManifest"] as? [[String:Any]] ?? []
        try require(manifest.count >= 5 && manifest.allSatisfy { $0["status"] as? String == "bundled" },"images CSS backgrounds pseudo elements and font bundled")
        try require(manifest.contains { $0["conversion"] as? String == "svg-to-png" },"external SVG rasterized without source scripts")
        let html = try String(contentsOf:capture.directory.appendingPathComponent("reference.html"),encoding:.utf8)
        try require(!html.contains("pageglass_asset_") && !html.contains(base.absoluteString) && !html.contains("must not run"),"resource markers resolved to local files and SVG script excluded")
        try require(html.contains("qa-symbol") && html.contains("qa-gradient"),"SVG symbol and gradient outside selected subtree retained")
        // Load in a fresh WebKit store while explicitly blocking every HTTP request.
        let replay = BrowserWindow(privateBrowsing:true,store:browser.store); replay.showWindow(nil)
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"pageglass-offline-smoke",encodedContentRuleList:rules)!
        replay.webView.configuration.userContentController.add(ruleList)
        let exported = capture.directory.appendingPathComponent("reference.html")
        replay.load(exported); try await loaded(replay.webView,url:exported)
        let state:Any? = try await withCheckedThrowingContinuation { continuation in
            replay.webView.callAsyncJavaScript("await document.fonts.ready;return {images:[...document.images].every(i=>i.complete&&i.naturalWidth>0),font:document.fonts.check('16px CaptureFixture'),checked:document.querySelector('#checked').checked,open:document.querySelector('#details').open,bbox:document.querySelector('use').getBBox().width}",arguments:[:],in:nil,in:CaptureService.world) { continuation.resume(with:$0) }
        }
        let values = state as? [String:Any] ?? [:]
        try require(values["images"] as? Bool == true && values["font"] as? Bool == true,"exported images and font render with network blocked")
        try require(values["checked"] as? Bool == true && values["open"] as? Bool == true,"live checkbox and details states survive export")
        try require((values["bbox"] as? Double ?? 0)>50,"offline SVG use has actual rendered geometry")
        let rect = try await replay.webView.evaluateJavaScript("(()=>{const r=document.querySelector('#card').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()") as? [String:Double] ?? [:]
        let configuration = WKSnapshotConfiguration(); configuration.rect = NSRect(x:rect["x"] ?? 0,y:rect["y"] ?? 0,width:rect["width"] ?? 1,height:rect["height"] ?? 1)
        configuration.snapshotWidth = NSNumber(value:min(rect["width"] ?? 1,900))
        let image = try await replay.webView.takeSnapshot(configuration:configuration)
        if let data = image.tiffRepresentation,let bitmap = NSBitmapImageRep(data:data),let png = bitmap.representation(using:.png,properties:[:]) { try png.write(to:output.appendingPathComponent("offline-assets.png")) }
        if let originalData = capture.image.tiffRepresentation,let replayData = image.tiffRepresentation,let original = NSBitmapImageRep(data:originalData),let copy = NSBitmapImageRep(data:replayData) {
            try require(original.pixelsWide == copy.pixelsWide && original.pixelsHigh == copy.pixelsHigh,"offline selected region keeps exact raster dimensions")
            var difference = 0.0, samples = 0
            for y in stride(from:0,to:original.pixelsHigh,by:3) {
                for x in stride(from:0,to:original.pixelsWide,by:3) {
                    guard let a = original.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),let b = copy.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
                    difference += abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent); samples += 3
                }
            }
            let average = difference/Double(max(samples,1))
            try JSONSerialization.data(withJSONObject:["meanAbsoluteRGBError":average,"sampledChannels":samples,"width":copy.pixelsWide,"height":copy.pixelsHigh],options:.prettyPrinted).write(to:output.appendingPathComponent("offline-visual-comparison.json"))
            try require(samples > 0 && average < 0.01,"offline fixture mean RGB error below one percent")
        } else { throw CaptureService.Failure.message("offline screenshot comparison decode failed") }
        replay.window?.close()
        let denied = URL(string:base.absoluteString.replacingOccurrences(of:"127.0.0.1",with:"localhost"))!.appendingPathComponent("fixture.png").absoluteString
        let references = [denied,base.appendingPathComponent("not-an-image").absoluteString,base.appendingPathComponent("oversized").absoluteString].enumerated().map { ["url":$0.element,"token":"test-resource-\($0.offset)","context":"html"] }
        let failure = try await CaptureAssets.bundle(view,html:"test-resource-0 test-resource-1 test-resource-2",references:references,folder:output.appendingPathComponent("rejected-assets"))
        try require(failure.manifest.count == 3 && failure.manifest.allSatisfy { $0["file"] == nil } && !failure.warnings.isEmpty,"CORS denial oversized file and disguised HTML fail explicitly")
        return checks
    }
}
