import AppKit
import WebKit

@MainActor
enum InteractionSmoke {
    static func run(_ browser:BrowserWindow,base:URL,output:URL) async throws -> [String] {
        var checks:[String] = []
        func require(_ value:Bool,_ label:String) throws { if !value { throw CaptureService.Failure.message(label) };checks.append(label) }
        func loaded(_ view:WKWebView,_ url:URL) async throws {
            for _ in 0..<100 { try await Task.sleep(for:.milliseconds(100));if !view.isLoading,view.url == url { return } }
            throw CaptureService.Failure.message("interaction fixture load timeout")
        }
        let url = base.appendingPathComponent("capture-fixture.html")
        browser.load(url);try await loaded(browser.webView,url)
        let view = browser.webView,recorder = browser.interactionRecording!
        // Owned fixture only: test events exercise the real isolated-world bridge and snapshots.
        _ = try await view.evaluateJavaScript("""
        document.querySelector('#details').open=false;
        document.body.insertAdjacentHTML('beforeend','<textarea id="draft">private-interaction-draft</textarea><div contenteditable id="editable">private-editable-draft</div><input id="password" type="password" value="private-password">');
        """)
        let inactive = try await browser.captureService.js(view,"globalThis.__pageglassRecorder.revision()") as? [String:Any]
        try require(inactive?["enabled"] as? Bool == false,"interaction observer inactive before explicit start")
        try await recorder.start(view)
        try require(recorder.frames.count == 1 && recorder.frames[0].png != nil,"interaction initial screenshot and structure captured")
        func settled(_ count:Int) async throws {
            for _ in 0..<100 {
                try await Task.sleep(for:.milliseconds(100))
                if recorder.frames.count >= count,recorder.frames[count-1].step["frameStatus"] != nil { return }
            }
            throw CaptureService.Failure.message("interaction state capture timeout")
        }
        _ = try await view.evaluateJavaScript("const summary=document.querySelector('summary');summary.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));summary.click()")
        try await settled(2)
        let step = recorder.frames[1].step
        try require((step["before"] as? [String:Any])?["open"] as? Bool == false && (step["after"] as? [String:Any])?["open"] as? Bool == true,"interaction log preserves observed details before and after")
        try require(recorder.frames[1].png != nil && !(step["changes"] as? [[String:Any]] ?? []).isEmpty,"interaction changed DOM and resulting frame captured")
        _ = try await view.evaluateJavaScript("document.querySelector('#draft').value='new-private-input';document.querySelector('#draft').dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('#password').dispatchEvent(new Event('change',{bubbles:true}))")
        try await settled(3)
        guard let history = await recorder.finish(view) else { throw CaptureService.Failure.message("interaction archive missing") }
        try require(history.frames.count == 3 && !recorder.isRecording,"password events excluded and explicit stop ends recording")
        let serialized = String(decoding:try JSONSerialization.data(withJSONObject:history.frames.map { ["step":$0.step,"extraction":$0.extraction ?? [:]] }),as:UTF8.self)
        try require(!["private-interaction-draft","private-editable-draft","private-password","new-private-input"].contains(where:serialized.contains),"typed values excluded from interaction log HTML and metadata")
        _ = try await view.evaluateJavaScript("document.querySelector('summary').click()")
        try await Task.sleep(for:.milliseconds(400))
        try require(recorder.frames.count == 3,"stopped recording receives no later page operations")
        let result = try await browser.captureService.capture(view,mode:"page",destination:output,interactionHistory:history) { _ in }
        let folder = result.directory.appendingPathComponent("interaction-history")
        let timeline = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("timeline.json"))) as? [String:Any]
        let steps = timeline?["steps"] as? [[String:Any]] ?? []
        try require(steps.count == 3 && steps.allSatisfy { $0["screenshot"] != nil && $0["html"] != nil },"capture bundle includes every settled interaction state")
        let firstHTML = try String(contentsOf:folder.appendingPathComponent("state-00.html"),encoding:.utf8)
        try require(firstHTML.contains("../assets/") && !firstHTML.contains("pageglass_asset_"),"interaction assets resolve relative to shared offline bundle")
        let replay = BrowserWindow(privateBrowsing:true,store:browser.store);replay.showWindow(nil)
        defer { replay.window?.close() }
        let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"pageglass-interaction-offline",encodedContentRuleList:"[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]")!
        replay.webView.configuration.userContentController.add(rule)
        let preview = result.directory.appendingPathComponent("interaction-history.html")
        replay.load(preview);try await loaded(replay.webView,preview)
        for (name,expected) in [("state-00.html",false),("state-01.html",true)] {
            let file = folder.appendingPathComponent(name)
            _ = try await replay.webView.evaluateJavaScript("location.href=\"\(file.absoluteString)\"")
            try await loaded(replay.webView,file)
            let values = try await replay.webView.evaluateJavaScript("({open:document.querySelector('#details').open,images:[...document.images].every(i=>i.complete&&i.naturalWidth>0)})") as? [String:Any]
            try require(values?["open"] as? Bool == expected && values?["images"] as? Bool == true,"offline interaction \(name) retains its own state and images")
        }
        try await recorder.start(view)
        _ = try await view.evaluateJavaScript("for(let i=0;i<10;i++){const e=document.createElement('button');e.textContent='Rapid '+i;document.body.appendChild(e);e.click()}")
        try await settled(9)
        let bounded = await recorder.finish(view)
        try require(bounded?.frames.count == 9 && !recorder.isRecording,"interaction automatically stops at eight actions")
        try require(bounded?.frames.dropFirst().contains(where:{$0.png == nil && ($0.step["frameStatus"] as? String)?.hasPrefix("skipped-") == true}) == true,"rapid operations explicitly mark uncaptured frames instead of mislabeling images")
        try await recorder.start(view)
        _ = try await view.evaluateJavaScript("document.querySelector('summary').click()")
        browser.selectElement()
        for _ in 0..<100 { if browser.selecting { break };try await Task.sleep(for:.milliseconds(100)) }
        try require(browser.selecting && !recorder.isRecording && recorder.frames.count == 2 && recorder.frames[1].png != nil,"element picker flushes last pending interaction before selecting")
        browser.selectElement()
        try await recorder.start(view)
        let previous = browser.activeIndex
        browser.newTab()
        try require(!recorder.isRecording && !recorder.frames.isEmpty,"switching tabs stops recording and preserves existing history")
        browser.activate(previous)
        browser.load(url);try await loaded(view,url)
        try require(recorder.frames.isEmpty && !recorder.isRecording,"full navigation clears previous document interaction history")
        try await recorder.start(view)
        browser.load(base.appendingPathComponent("broken-navigation"))
        for _ in 0..<100 { try await Task.sleep(for:.milliseconds(100));if !view.isLoading { break } }
        let afterFailure = try await browser.captureService.js(view,"globalThis.__pageglassRecorder.revision()") as? [String:Any]
        try require(view.url == url && !view.isLoading && !recorder.isRecording && afterFailure?["enabled"] as? Bool == false,"failed navigation stops recorder even when previous document survives")
        return checks
    }
}
