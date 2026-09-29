import AppKit
import WebKit

/// 直接在实际 WKWebView 内验证捕获，不依赖 DOM mock；只使用随包测试页面。
@MainActor
enum SmokeTest {
    static func run(_ browser:BrowserWindow,output:URL) async {
        var checks: [String] = []
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            browser.load(Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources")!)
            for _ in 0..<100 {
                try await Task.sleep(for:.milliseconds(100))
                if !browser.webView.isLoading, browser.webView.title == "工作台 · 捕获练习" { break }
            }
            let view = browser.webView, capture = browser.captureService
            guard view.title == "工作台 · 捕获练习" else { throw CaptureService.Failure.message("fixture load timeout") }
            func require(_ value:Bool,_ label:String) throws {
                if !value { throw CaptureService.Failure.message(label) }; checks.append(label)
            }
            try await browser.interactionRecording?.start(view)
            _ = try await view.evaluateJavaScript("document.querySelector('#new-request').click()")
            let state = try await view.evaluateJavaScript("document.querySelector('#new-request').getAttribute('aria-expanded')") as? String
            try require(state == "true","live button interaction")
            let observedHistory = await browser.interactionRecording?.finish(view)
            _ = try await capture.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
            let element = try await capture.capture(view,mode:"element",destination:output) { _ in }
            try require((element.metadata["nodeCount"] as? Int ?? 0) >= 4,"element subtree export")
            try require(element.image.size.width > 100 && element.image.size.height > 50,"element PNG size")
            let cleanPage = try await capture.capture(view,mode:"page",destination:output,interactionHistory:observedHistory) { _ in }
            _ = try await view.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<input type=password value=secret-test><input type=hidden value=hidden-secret><textarea>private-draft</textarea><div id=security-fixture><a onclick=alert(1) href=javascript:alert(1)>unsafe</a></div>'); window.scrollTo(0,120)")
            let before = try await view.evaluateJavaScript("scrollY") as? Double ?? 0
            let page = try await capture.capture(view,mode:"page",destination:output) { _ in }
            let after = try await view.evaluateJavaScript("scrollY") as? Double ?? -1
            let html = try String(contentsOf:page.directory.appendingPathComponent("reference.html"),encoding:.utf8)
            try require(abs(before-after)<1,"scroll restored after tiled capture")
            try require(!html.contains("secret-test") && !html.contains("hidden-secret") && !html.contains("private-draft"),"private input values excluded from code")
            try require(!html.contains("onclick=") && !html.contains("href=\"javascript:"),"executable attributes excluded")
            try require(html.contains("Content-Security-Policy") && html.contains("END OF CAPTURE"),"standalone HTML and document end")
            let interactions = page.metadata["interactions"] as? [[String:Any]] ?? []
            try require(interactions.contains { $0["expanded"] as? String == "true" },"expanded interaction recorded")
            let count = page.metadata["nodeCount"] as? Int ?? 0
            try require(count > 50,"full DOM export")
            try require(page.image.size.height > view.bounds.height,"full page screenshot exceeds viewport")
            page.copyForCodex()
            try require(CaptureClipboard.current.string(forType:.string)?.contains(page.directory.path) == true,"clipboard contains screenshot and code bundle path")
            let gpu = try await view.evaluateJavaScript("(()=>{const c=document.createElement('canvas');const gl=c.getContext('webgl2')||c.getContext('webgl');if(!gl)return {available:false};const e=gl.getExtension('WEBGL_debug_renderer_info');return {available:true,renderer:e?gl.getParameter(e.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER),vendor:e?gl.getParameter(e.UNMASKED_VENDOR_WEBGL):gl.getParameter(gl.VENDOR)}})()")
            try require((gpu as? [String:Any])?["available"] as? Bool == true,"WebGL context available")
            // 重开实际导出的 HTML，验证计算样式仍保持所选卡片几何。
            browser.load(element.directory.appendingPathComponent("reference.html"))
            for _ in 0..<100 {
                try await Task.sleep(for:.milliseconds(50))
                if !view.isLoading, view.url?.lastPathComponent == "reference.html" { break }
            }
            let replay = try await view.evaluateJavaScript("(()=>{const r=document.querySelector('[data-pg-id=pg-1]').getBoundingClientRect();return {width:r.width,height:r.height}})()") as? [String:Double]
            let sourceRect = element.metadata["rect"] as? [String:Double] ?? [:]
            try require(abs((replay?["width"] ?? 0)-(sourceRect["width"] ?? 10000)) < 1 && abs((replay?["height"] ?? 0)-(sourceRect["height"] ?? 10000)) < 1,"exported HTML preserves selected card geometry")
            checks += try await BrowserFeatureSmoke.run(browser)
            if let index = CommandLine.arguments.firstIndex(of:"--asset-test-url"),CommandLine.arguments.count > index+1,let base = URL(string:CommandLine.arguments[index+1]) {
                checks += try await CaptureAssetSmoke.run(browser,base:base,output:output)
                checks += try await InteractionSmoke.run(browser,base:base,output:output)
                checks += try await WorkflowSmoke.loadingEscape(browser,base:base)
            }
            checks += try await DeveloperToolsSmoke.run(browser)
            checks += try await ChromeLayoutSmoke.run(output:output)
            checks += try await ExperienceSmoke.run(output:output)
            checks += try await CaptureFlowSmoke.run(browser,output:output)
            checks += try await WorkflowSmoke.run(browser,output:output)
            checks += try await CaptureLibrarySmoke.run(browser,output:output)
            checks += try await CaptureEditingSmoke.run(browser,output:output)
            if #available(macOS 15.4,*),let index = CommandLine.arguments.firstIndex(of:"--asset-test-url"),CommandLine.arguments.count > index+1,let base = URL(string:CommandLine.arguments[index+1]) {
                checks += try await ExtensionSmoke.run(base:base,output:output)
            }
            let report: [String:Any] = ["passed":checks,"gpu":gpu ?? NSNull(),"element":element.directory.path,"page":page.directory.path,"cleanPage":cleanPage.directory.path,"viewport":["width":view.bounds.width,"height":view.bounds.height],"status":"passed"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
            browser.latest = page; browser.status.stringValue = "实机自动检查通过：\(checks.count) 项"
            print("SMOKE PASS \(checks.count) \(output.path)")
            if CommandLine.arguments.contains("--review-capture") { browser.performCapture(mode:"page") }
            if CommandLine.arguments.contains("--exit") { CaptureClipboard.finishTesting(); NSApp.terminate(nil) }
        } catch {
            let report: [String:Any] = ["passed":checks,"error":error.localizedDescription,"status":"failed"]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted]) { try? data.write(to:output.appendingPathComponent("report.json")) }
            print("SMOKE FAIL \(error)")
            if CommandLine.arguments.contains("--exit") { CaptureClipboard.finishTesting(); exit(1) }
        }
    }
}
