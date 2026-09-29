import AppKit
import WebKit

@MainActor
enum CaptureFlowSmoke {
    static func run(_ browser:BrowserWindow,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ value:Bool,_ message:String) throws { if !value { throw CaptureService.Failure.message(message) }; checks.append(message) }
        let fixture = Resources.bundle.url(forResource:"demo",withExtension:"html",subdirectory:"Resources")!
        browser.load(fixture)
        for _ in 0..<100 { if browser.webView.url == fixture,!browser.webView.isLoading { break }; try await Task.sleep(for:.milliseconds(50)) }
        let root = output.appendingPathComponent("cancel-checks"), service = browser.captureService, view = browser.webView
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for phase in ["正在生成截图…","正在保存图片与字体…","正在保存捕获包…"] {
            _ = try await service.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
            var task:Task<CaptureResult,Error>?
            task = Task { @MainActor in try await service.capture(view,mode:"element",destination:root) { if $0 == phase { task?.cancel() } } }
            var cancelled = false
            do { _ = try await task!.value } catch is CancellationError { cancelled = true }
            try require(cancelled && (try FileManager.default.contentsOfDirectory(atPath:root.path)).isEmpty,"cancel during \(phase) leaves no completed or pending package")
        }
        let sentinel = "pageglass-cancel-keeps-clipboard"
        CaptureClipboard.current.clearContents(); CaptureClipboard.current.setString(sentinel,forType:.string)
        _ = try await view.evaluateJavaScript("window.scrollTo(0,120)")
        let before = try await view.evaluateJavaScript("scrollY") as? Double ?? 0
        browser.performCapture(mode:"page"); let task = browser.captureTask
        try await Task.sleep(for:.milliseconds(50)); browser.cancelCapture(); await task?.value
        let after = try await view.evaluateJavaScript("scrollY") as? Double ?? -1
        try require(!browser.capturing && browser.captureTask == nil && abs(before-after)<1,"cancelled page capture restores scrolling and browser controls")
        try require(CaptureClipboard.current.string(forType:.string) == sentinel,"cancelled capture preserves previous clipboard")
        let overlays = try await service.js(view,"document.querySelectorAll('[data-pageglass-overlay]').length") as? Int
        try require(overlays == 0,"cancelled capture removes temporary styles and overlays")
        let blocked = output.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to:blocked)
        _ = try await service.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
        var failed = false
        do { _ = try await service.capture(view,mode:"element",destination:blocked) { _ in } } catch { failed = true }
        try require(failed,"write failure cannot report a completed capture")
        let result = try await service.capture(view,mode:"element",destination:root) { _ in }
        try require(result.metadata["outcome"] as? String == "complete","simple element capture has structured complete outcome")
        let record = CaptureCatalog.record(result.directory)
        try require(record.problem == nil && CaptureCatalog.thumbnail(result.directory) != nil,"saved capture is discoverable with a decoded preview")
        try CaptureCatalog.copyPrompt(result.directory)
        try require(CaptureClipboard.current.string(forType:.string) == result.prompt,"capture history can recopy original local handoff")
        let originalSettings = browser.store.state.settings
        var manualCopySettings = originalSettings; manualCopySettings.autoCopyCapture = false
        browser.store.updateSettings(manualCopySettings)
        CaptureClipboard.current.clearContents(); CaptureClipboard.current.setString(sentinel,forType:.string)
        _ = try await service.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
        let previousResult = browser.latest?.directory
        browser.performCapture(mode:"element"); await browser.captureTask?.value
        browser.store.updateSettings(originalSettings)
        try require(browser.latest?.directory != previousResult && browser.latest != nil && !browser.capturing,"capture with auto-copy disabled still saves a completed package")
        try require(CaptureClipboard.current.string(forType:.string) == sentinel,"disabling auto-copy preserves the clipboard on successful capture")
        browser.copyLatest()
        try require(CaptureClipboard.current.string(forType:CaptureRetention.clipboardType) == browser.latest?.directory.path,"manual copy remains available when auto-copy is disabled")
        browser.captureResultController?.close()
        let reference = result.directory.appendingPathComponent("reference.html")
        try "<!doctype html><title>Script-free preview test</title><body>Preview<script>document.body.dataset.executed='yes'</script>".write(to:reference,atomically:true,encoding:.utf8)
        let preview = try CaptureReferenceController(directory:result.directory); preview.showWindow(nil)
        defer { preview.close() }
        let referenceView = preview.window!.contentView as! WKWebView
        for _ in 0..<100 { if !referenceView.isLoading,referenceView.url == reference { break }; try await Task.sleep(for:.milliseconds(50)) }
        let executed = try await service.js(referenceView,"document.body.dataset.executed || ''") as? String
        try require(executed == "","reference preview blocks scripts even if package HTML is modified")
        preview.close()
        try require(!(preview.window?.contentView is WKWebView),"closing reference preview releases its WebView")
        guard let argument = CommandLine.arguments.firstIndex(of:"--asset-test-url"),CommandLine.arguments.count > argument+1,let base = URL(string:CommandLine.arguments[argument+1]) else { throw CaptureService.Failure.message("capture flow checks require the local fixture server") }
        browser.load(base.appendingPathComponent("demo.html"))
        for _ in 0..<100 { if view.url == base.appendingPathComponent("demo.html"),!view.isLoading { break }; try await Task.sleep(for:.milliseconds(50)) }
        _ = try await view.evaluateJavaScript("document.querySelector('#metric-card').style.backgroundImage='url(/not-an-image)'")
        _ = try await service.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
        let partial = try await service.capture(view,mode:"element",destination:root) { _ in }
        try require(partial.metadata["outcome"] as? String == "partial" && (partial.metadata["qualityIssues"] as? [String])?.contains("missing-assets") == true,"failed asset is a structured partial capture with a usable screenshot")
        let partialRecord = CaptureCatalog.record(partial.directory)
        try require(partialRecord.outcome == "部分捕获" && !partialRecord.warnings.isEmpty && partialRecord.problem == nil,"history distinguishes partial results from unreadable packages")
        _ = try await view.evaluateJavaScript("document.querySelector('#metric-card').style.cssText='position:fixed;top:20px;left:20px;width:400px;height:1500px;background:white'")
        _ = try await service.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
        let clipped = try await service.capture(view,mode:"element",destination:root) { _ in }
        try require((clipped.metadata["qualityIssues"] as? [String])?.contains("element-clipped") == true && clipped.metadata["outcome"] as? String == "partial","clipped element reports partial capture instead of complete")
        let token = UUID().uuidString
        _ = try await view.evaluateJavaScript("document.querySelector('#metric-card').style.cssText='background-image:url(/slow-image/\(token))'")
        _ = try await service.js(view,"globalThis.__pageglass.selectForTest('#metric-card')")
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath:browser.captureRoot.path)) ?? [])
        CaptureClipboard.current.clearContents(); CaptureClipboard.current.setString(sentinel,forType:.string)
        browser.performCapture(mode:"element"); let inFlight = browser.captureTask
        var fetching = false
        for _ in 0..<300 {
            if browser.captureTask == nil { break }
            if browser.captureProgress == "正在保存图片与字体…",(try await service.js(view,"typeof globalThis.__pageglassAbortAssets === 'function'")) as? Bool == true {
                let (data,_) = try await URLSession.shared.data(from:base.appendingPathComponent("slow-state/\(token)"))
                fetching = (try JSONSerialization.jsonObject(with:data) as? [String:Bool])?["active"] == true
                if fetching { break }
            }
            try await Task.sleep(for:.milliseconds(50))
        }
        let phaseAtCancel = browser.captureProgress
        let cancelledAt = Date(); browser.cancelCapture(); await inFlight?.value
        try require(fetching,"cancel check reaches an actual resource response still in flight (phase: \(phaseAtCancel))")
        try require(Date().timeIntervalSince(cancelledAt)<4 && !browser.capturing,"cancelling aborts the resource stream without waiting for its five-second response")
        try require((try await service.js(view,"typeof globalThis.__pageglassAbortAssets")) as? String == "undefined","resource cancellation removes its isolated abort hook")
        try require(Set((try? FileManager.default.contentsOfDirectory(atPath:browser.captureRoot.path)) ?? []) == existing && CaptureClipboard.current.string(forType:.string) == sentinel,"in-flight cancellation leaves no package and preserves clipboard")
        return checks
    }
}
