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
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sentinel,forType:.string)
        _ = try await view.evaluateJavaScript("window.scrollTo(0,120)")
        let before = try await view.evaluateJavaScript("scrollY") as? Double ?? 0
        browser.performCapture(mode:"page"); let task = browser.captureTask
        try await Task.sleep(for:.milliseconds(50)); browser.cancelCapture(); await task?.value
        let after = try await view.evaluateJavaScript("scrollY") as? Double ?? -1
        try require(!browser.capturing && browser.captureTask == nil && abs(before-after)<1,"cancelled page capture restores scrolling and browser controls")
        try require(NSPasteboard.general.string(forType:.string) == sentinel,"cancelled capture preserves previous clipboard")
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
        try require(NSPasteboard.general.string(forType:.string) == result.prompt,"capture history can recopy original local handoff")
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
        return checks
    }
}
