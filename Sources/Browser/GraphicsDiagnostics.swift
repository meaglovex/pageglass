import AppKit
import WebKit
import Metal
import VideoToolbox

struct GraphicsCheck:Codable,Equatable {
    enum Status:String,Codable { case passed,unavailable,failed,unknown }
    let status:Status
    let detail:String
    var renderer:String?
    var vendor:String?
    var pixels:[Int]?
    var value:Int?

    static func parse(_ raw:Any?,api:String)->GraphicsCheck {
        guard let data = raw as? [String:Any],let text = data["status"] as? String,let status = Status(rawValue:text),
              let detail = data["detail"] as? String else { return .init(status:.unknown,detail:"未取得有效检测结果") }
        let pixels = data["pixels"] as? [Int],value = data["value"] as? Int
        let renderer = (data["renderer"] as? String).map { String($0.prefix(160)) }
        if status == .passed {
            let valid:Bool
            if api == "webgpu" { valid = value == 42 }
            else { valid = pixels?.count == 4 && (pixels ?? []).allSatisfy { (0...255).contains($0) } && zip(pixels ?? [],[32,128,223,255]).allSatisfy { abs($0-$1) <= 2 } && renderer?.isEmpty == false }
            guard valid else { return .init(status:.unknown,detail:"检测结果缺少有效的读回证据") }
        }
        return .init(status:status,detail:String(detail.prefix(240)),renderer:renderer,vendor:(data["vendor"] as? String).map { String($0.prefix(160)) },pixels:pixels,value:value)
    }
    var summary:String {
        switch status {
        case .passed: return "通过"
        case .unavailable: return "不可用"
        case .failed: return "未通过"
        case .unknown: return "未确认"
        }
    }
}

struct GraphicsReport:Codable {
    struct Device:Codable { let name:String; let lowPower:Bool; let unifiedMemory:Bool }
    struct Decoder:Codable { let codec:String; let hardwareSupported:Bool }
    let sampledAt:Date
    let appVersion:String
    let appBuild:String
    let osVersion:String
    let accelerationPolicy:String
    let devices:[Device]
    let decoders:[Decoder]
    var webgl:GraphicsCheck
    var webgl2:GraphicsCheck
    var webgpu:GraphicsCheck
    var secureContext:Bool?
    var error:String?
    let scope:String

    static func systemSnapshot()->GraphicsReport {
        let devices = MTLCopyAllDevices().map { Device(name:$0.name,lowPower:$0.isLowPower,unifiedMemory:$0.hasUnifiedMemory) }
        let unknown = GraphicsCheck(status:.unknown,detail:"尚未完成网页图形检测")
        return .init(sampledAt:Date(),appVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development",appBuild:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "development",osVersion:ProcessInfo.processInfo.operatingSystemVersionString,accelerationPolicy:"由系统 WebKit 自动管理，无应用级强制开关",devices:devices,
                     decoders:[("H.264",kCMVideoCodecType_H264),("HEVC",kCMVideoCodecType_HEVC),("AV1",kCMVideoCodecType_AV1)].map { Decoder(codec:$0.0,hardwareSupported:VTIsHardwareDecodeSupported($0.1)) },
                     webgl:unknown,webgl2:unknown,webgpu:unknown,scope:"本地独立测试文档；绘制或计算读回不是所有网页的加速保证；硬解码支持不是当前视频实际解码路径。")
    }
    var json:String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data:$0,encoding:.utf8) }
    }
}

/// One user-requested check. No timers or retained WebView after completion/cancel.
@MainActor
final class GraphicsDiagnostics:NSObject,WKNavigationDelegate {
    private(set) var webView:WKWebView?
    private var timeoutTask:Task<Void,Never>?
    private var completion:((GraphicsReport)->Void)?
    private var report:GraphicsReport?
    private var generation = UUID()
    private var fixture:URL?
    static let world = WKContentWorld.world(name:"PageglassGraphicsDiagnostics")

    func run(timeout:Duration = .seconds(10),completion:@escaping (GraphicsReport)->Void) {
        cancel()
        let token = generation
        self.completion = completion; report = .systemSnapshot()
        guard let html = Resources.bundle.url(forResource:"graphics-diagnostics",withExtension:"html",subdirectory:"Resources") else { finish(error:"检测页面缺失"); return }
        fixture = html
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame:NSRect(x:0,y:0,width:64,height:64),configuration:configuration)
        webView = view; view.navigationDelegate = self
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:timeout) } catch { return }
            guard let self,self.generation == token else { return }
            self.finish(error:"检测超时，请重试")
        }
        view.loadFileURL(html,allowingReadAccessTo:html.deletingLastPathComponent())
    }
    func cancel() {
        generation = UUID(); timeoutTask?.cancel(); timeoutTask = nil
        completion = nil; report = nil; fixture = nil
        webView?.navigationDelegate = nil; webView?.stopLoading(); webView = nil
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        decisionHandler(navigationAction.request.url == fixture ? .allow : .cancel)
    }
    func webView(_ view:WKWebView,didFinish navigation:WKNavigation!) {
        guard view === webView,let url = Resources.bundle.url(forResource:"graphics-diagnostics",withExtension:"js",subdirectory:"Resources"),let script = try? String(contentsOf:url,encoding:.utf8) else { finish(error:"检测脚本缺失"); return }
        let token = generation
        view.callAsyncJavaScript(script,arguments:[:],in:nil,in:Self.world) { [weak self] result in
            guard let self,self.generation == token else { return }
            switch result {
            case .success(let value):
                guard let data = value as? [String:Any] else { self.finish(error:"未取得有效网页检测结果"); return }
                self.report?.webgl = .parse(data["webgl"],api:"webgl")
                self.report?.webgl2 = .parse(data["webgl2"],api:"webgl2")
                self.report?.webgpu = .parse(data["webgpu"],api:"webgpu")
                self.report?.secureContext = data["secureContext"] as? Bool
                self.finish()
            case .failure: self.finish(error:"网页图形检测未能完成，请重试")
            }
        }
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { finish(error:"无法完成检测页面加载") }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { finish(error:"无法加载本地检测页面") }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) { finish(error:"图形检测进程已结束，请重试") }
    private func finish(error:String? = nil) {
        guard var value = report else { return }
        value.error = error
        let callback = completion
        cancel()
        callback?(value)
    }
}
