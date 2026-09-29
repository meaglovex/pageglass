import AppKit
import WebKit

struct InteractionFrame {
    var step:[String:Any]
    var extraction:[String:Any]?
    var png:Data?
}
struct InteractionArchive {
    var frames:[InteractionFrame]
    var warnings:[String]
    var references:[[String:String]] { frames.flatMap { $0.extraction?["assetReferences"] as? [[String:String]] ?? [] } }
}

@MainActor
final class InteractionRecording {
    static let script = (try? String(contentsOf:Resources.bundle.url(forResource:"interaction-recorder",withExtension:"js",subdirectory:"Resources")!,encoding:.utf8)) ?? ""
    private(set) var isRecording = false
    private(set) var frames:[InteractionFrame] = []
    private(set) var warnings:[String] = []
    private var documentID:String?
    private var generation = UUID()
    private var task:Task<Void,Never>?
    private var usedBytes = 0
    var onChange:(()->Void)?

    func start(_ view:WKWebView) async throws {
        reset(); isRecording = true; onChange?()
        let token = generation
        let raw = try await CaptureService().js(view,"globalThis.__pageglassRecorder.start()") as? [String:Any]
        guard token == generation else { return }
        guard let id = raw?["documentID"] as? String,let first = raw?["step"] as? [String:Any] else { reset(); throw CaptureService.Failure.message("页面未能启动交互记录") }
        documentID = id; receive(first,document:id,view:view)
        await task?.value
    }
    func receive(_ step:[String:Any],document:String,view:WKWebView) {
        guard isRecording,document == documentID,let sequence = step["sequence"] as? Int,(0...8).contains(sequence),!frames.contains(where:{$0.step["sequence"] as? Int == sequence}),let encoded = try? JSONSerialization.data(withJSONObject:step),encoded.count < 64_000 else { return }
        let index = frames.count
        frames.append(InteractionFrame(step:step))
        if sequence >= 8 { isRecording = false;warnings.append("已记录 8 次操作，自动停止；重新开始记录会替换此段历史。"); }
        onChange?()
        if task != nil { frames[index].step["frameStatus"] = "skipped-busy"; warnings.append("快速连续操作期间有画面未保存；操作日志仍保留，不把后续画面冒充前一步。"); return }
        let token = generation
        task = Task { @MainActor [weak self,weak view] in
            guard let self,let view else { return }
            defer { if token == generation { task = nil; onChange?() } }
            @MainActor func mark(_ status:String) { if token == generation,frames.indices.contains(index) { frames[index].step["frameStatus"] = status } }
            do {
                @MainActor func revisionMatches() async throws -> Bool {
                    let revision = try await CaptureService().js(view,"globalThis.__pageglassRecorder.revision()") as? [String:Any]
                    return revision?["documentID"] as? String == document && revision?["sequence"] as? Int == sequence
                }
                guard try await revisionMatches() else { mark("skipped-newer-action"); return }
                guard let extraction = try await CaptureService().js(view,"globalThis.__pageglass.extract('page')") as? [String:Any],extraction["html"] is String else { throw CaptureService.Failure.message("交互状态结构不可用") }
                let configuration = WKSnapshotConfiguration();configuration.rect = view.bounds;configuration.snapshotWidth = 900;configuration.afterScreenUpdates = true
                let image = try await view.takeSnapshot(configuration:configuration)
                guard token == generation,!Task.isCancelled,frames.indices.contains(index) else { return }
                guard try await revisionMatches() else { mark("skipped-changed-during-capture"); return }
                guard let tiff = image.tiffRepresentation,let bitmap = NSBitmapImageRep(data:tiff),let png = bitmap.representation(using:.png,properties:[:]) else { throw CaptureService.Failure.message("交互截图编码失败") }
                guard token == generation,frames.indices.contains(index) else { return }
                let bytes = (try JSONSerialization.data(withJSONObject:extraction).count) + png.count
                if bytes+usedBytes > 20*1024*1024 { frames[index].step["frameStatus"] = "skipped-size-limit"; warnings.append("交互画面与结构合计达到 20 MiB，后续仅保存操作日志。"); return }
                usedBytes += bytes;frames[index].extraction = extraction;frames[index].png = png;frames[index].step["frameStatus"] = "captured";frames[index].step["frameCapturedAt"] = ISO8601DateFormatter().string(from:Date())
            } catch {
                if token == generation,frames.indices.contains(index) { frames[index].step["frameStatus"] = "failed";warnings.append("部分交互画面保存失败：\(error.localizedDescription)") }
            }
        }

    }
    func finish(_ view:WKWebView) async -> InteractionArchive? {
        if isRecording {
            if let last = try? await CaptureService().js(view,"globalThis.__pageglassRecorder.stop()") as? [String:Any],let documentID { receive(last,document:documentID,view:view) }
            isRecording = false;onChange?()
        }
        await task?.value
        guard !frames.isEmpty else { return nil }
        return InteractionArchive(frames:frames,warnings:Array(Set(warnings)).sorted())
    }
    func pause(_ view:WKWebView) {
        guard isRecording else { return }
        isRecording = false;onChange?()
        view.evaluateJavaScript("globalThis.__pageglassRecorder?.stop(false)",in:nil,in:CaptureService.world)
        warnings.append("切换标签时已停止记录；最后尚未稳定的操作可能未保存。");
    }
    func reset() { generation = UUID();task?.cancel();task = nil;documentID = nil;isRecording = false;frames = [];warnings = [];usedBytes = 0;onChange?() }
}

extension BrowserWindow {
    var interactionRecording:InteractionRecording? { tabs.indices.contains(activeIndex) ? tabs[activeIndex].recording : nil }
    @objc func toggleInteractionRecording() {
        guard !capturing,!selecting,let view = activeWebView,let recorder = interactionRecording else { return }
        recorder.onChange = { [weak self] in self?.syncChrome() }
        Task { @MainActor in
            if recorder.isRecording { _ = await recorder.finish(view);status.stringValue = "已停止交互记录 · 下次捕获会一起复制" }
            else {
                do { try await recorder.start(view);status.stringValue = recorder.isRecording ? "正在记录点击与画面 · 不记录键入内容 · 最多 8 次操作" : "交互记录已停止" }
                catch { recorder.reset();status.stringValue = "无法开始交互记录：\(error.localizedDescription)" }
            }
            syncChrome()
        }
    }
}

extension InteractionArchive {
    @MainActor
    func write(to folder:URL,assetPaths:[String:String]) throws -> [String:Any] {
        let directory = folder.appendingPathComponent("interaction-history",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var steps:[[String:Any]] = [], cards:[String] = []
        for (index,frame) in frames.enumerated() {
            var entry = frame.step
            let name = String(format:"state-%02d",index)
            if var extraction = frame.extraction,let html = extraction.removeValue(forKey:"html") as? String,let png = frame.png {
                let references = extraction.removeValue(forKey:"assetReferences") as? [[String:String]] ?? []
                let resolved = CaptureAssets.resolve(html,references:references,paths:assetPaths,prefix:"../")
                try resolved.write(to:directory.appendingPathComponent(name+".html"),atomically:true,encoding:.utf8)
                try png.write(to:directory.appendingPathComponent(name+".png"),options:.atomic)
                try JSONSerialization.data(withJSONObject:extraction,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(name+".json"),options:.atomic)
                entry["screenshot"] = name+".png";entry["html"] = name+".html";entry["structure"] = name+".json"
            }
            steps.append(entry)
            let target = entry["before"] as? [String:Any]
            let label = index == 0 ? "初始画面" : "步骤 \(index)：\(target?["label"] as? String ?? entry["kind"] as? String ?? "操作")"
            let picture = entry["screenshot"] as? String
            let frameLabel = picture == nil ? "仅保存操作日志，此步骤没有可用画面" : "已保存画面与页面结构"
            cards.append("<section><h2>\(CaptureAssets.escapeHTML(label))</h2><p>\(frameLabel)</p>" + (picture.map { "<a href=\"interaction-history/\(name).html\">打开此状态的页面结构</a><img src=\"interaction-history/\($0)\" alt=\"操作画面\">" } ?? "<p>此步骤没有画面，请查阅 interaction-history/timeline.json 中的原因。</p>") + "</section>")
        }
        let notes = ["仅记录用户主动开启后的当前文档操作；键入值不进入日志或代码，但截图可能包含可见个人信息。","画面通常在操作后约 350ms 采样；未覆盖异步响应的全部阶段，不推断后台逻辑。"] + warnings
        let timeline:[String:Any] = ["version":1,"steps":steps,"warnings":notes]
        try JSONSerialization.data(withJSONObject:timeline,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("timeline.json"),options:.atomic)
        let html = "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'\"><title>交互记录</title><style>body{max-width:1000px;margin:32px auto;padding:0 20px;font:15px -apple-system,sans-serif;color:#182234}section{border:1px solid #ddd;padding:20px;margin:24px 0;border-radius:12px}img{display:block;max-width:100%;margin-top:16px}a{color:#2464df}</style><h1>交互记录</h1><p>实际操作的画面与参考结构；未知交互不在此记录中。</p>" + cards.joined()
        try html.write(to:folder.appendingPathComponent("interaction-history.html"),atomically:true,encoding:.utf8)
        return ["file":"interaction-history/timeline.json","preview":"interaction-history.html","steps":steps.count,"capturedFrames":steps.filter{$0["screenshot"] != nil}.count]
    }
}
