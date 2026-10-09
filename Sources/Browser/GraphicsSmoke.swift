import AppKit

@MainActor
enum GraphicsSmoke {
    static func run(_ browser:BrowserWindow,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ label:String) throws {
            guard condition else { throw CaptureService.Failure.message(label) }; checks.append(label)
        }
        let settings = SettingsController(browser:browser)
        defer { settings.close() }
        settings.showGraphics(); settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
        let panel = settings.graphics
        try require(panel.diagnostics.webView == nil && panel.report == nil && !panel.copyButton.isEnabled,"graphics page does not run a probe before an explicit request")
        panel.runCheck()
        try require(!panel.runButton.isEnabled && !panel.copyButton.isEnabled,"graphics test prevents duplicate requests and stale report copies")
        for _ in 0..<120 {
            if panel.report != nil { break }; try await Task.sleep(for:.milliseconds(100))
        }
        guard let report = panel.report,let json = report.json else { throw CaptureService.Failure.message("graphics report did not finish") }
        try json.write(to:output.appendingPathComponent("graphics-report.json"),atomically:true,encoding:.utf8)
        try require(report.error == nil,"graphics probe finishes without navigation errors or timeout")
        try require(!report.devices.isEmpty,"system reports a real Metal graphics device")
        try require(report.webgl.status == .passed,"WebGL shader drawing and pixel readback succeed")
        try require(report.webgl2.status == .passed,"WebGL 2 shader drawing and pixel readback succeed")
        try require(report.webgpu.status == .passed || report.webgpu.status == .unavailable,"WebGPU is verified by computation or explicitly reported unavailable")
        try require(panel.diagnostics.webView == nil && panel.runButton.isEnabled && panel.copyButton.isEnabled,"finished diagnostics release the temporary WebView and enable the report")
        panel.copyReport()
        try require(CaptureClipboard.current.string(forType:.string) == json,"graphics copy action contains the actual measured JSON report")
        for theme in [NSAppearance.Name.aqua,.darkAqua] {
            settings.window?.appearance = NSAppearance(named:theme)
            settings.window?.setContentSize(NSSize(width:720,height:540)); settings.window?.contentView?.layoutSubtreeIfNeeded()
            let bounds = settings.window!.contentView!.bounds
            try require([panel.runButton,panel.copyButton,panel.outcome,panel.decoder].allSatisfy { view in bounds.contains(view.convert(view.bounds,to:settings.window!.contentView)) },"\(theme.rawValue) minimum graphics settings size keeps results and actions within the window")
        }
        panel.runCheck(); weak var cancelledView = panel.diagnostics.webView
        settings.close()
        try require(panel.diagnostics.webView == nil && panel.report == nil && !panel.copyButton.isEnabled,"closing settings cancels unfinished diagnostics without a stale report")
        try await Task.sleep(for:.milliseconds(200))
        try require(cancelledView == nil && panel.report == nil,"cancelled diagnostics release the WebView and ignore late completion")
        return checks
    }
}
