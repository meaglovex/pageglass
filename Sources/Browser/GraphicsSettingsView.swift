import AppKit

@MainActor
final class GraphicsSettingsView:NSStackView {
    let diagnostics = GraphicsDiagnostics()
    private(set) var report:GraphicsReport?
    let runButton = NSButton(title:"检测图形能力",target:nil,action:nil)
    let copyButton = NSButton(title:"复制诊断报告",target:nil,action:nil)
    let device = NSTextField(wrappingLabelWithString:"未检测")
    let webgl = NSTextField(wrappingLabelWithString:"未检测")
    let webgl2 = NSTextField(wrappingLabelWithString:"未检测")
    let webgpu = NSTextField(wrappingLabelWithString:"未检测")
    let decoder = NSTextField(wrappingLabelWithString:"未检测")
    let outcome = NSTextField(wrappingLabelWithString:"检测只使用本地测试页面，不读取当前网页。")

    init() {
        super.init(frame:.zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        let policy = NSTextField(labelWithString:"硬件加速 · 系统自动管理")
        policy.font = .systemFont(ofSize:14,weight:.semibold); addFull(policy)
        let description = NSTextField(wrappingLabelWithString:"WebKit 根据设备和页面选择图形处理方式。无需手动开启。")
        description.font = BrowserStyle.caption; description.textColor = BrowserStyle.supportingText; addFull(description)
        let separator = NSBox(); separator.boxType = .separator; addFull(separator)
        addValue("图形设备",device); addValue("WebGL 绘制",webgl); addValue("WebGL 2 绘制",webgl2); addValue("WebGPU 计算",webgpu); addValue("视频硬解码",decoder)
        for button in [runButton,copyButton] { button.bezelStyle = .rounded; button.target = self }
        runButton.action = #selector(runCheck); copyButton.action = #selector(copyReport); copyButton.isEnabled = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1),for:.horizontal)
        let actions = NSStackView(views:[runButton,copyButton,spacer]); actions.spacing = 8; addFull(actions)
        outcome.font = BrowserStyle.caption; outcome.textColor = BrowserStyle.supportingText; outcome.setAccessibilityLabel("图形检测状态"); addFull(outcome)
        let note = NSTextField(wrappingLabelWithString:"绘制通过不代表所有网页都使用硬件加速。视频项只说明系统支持，实际解码方式取决于视频和可用资源。")
        note.font = BrowserStyle.caption; note.textColor = BrowserStyle.supportingText; addFull(note)
    }
    required init?(coder:NSCoder) { fatalError() }
    private func addFull(_ view:NSView) { addArrangedSubview(view); view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
    private func addValue(_ title:String,_ value:NSTextField) {
        let label = NSTextField(labelWithString:title); label.font = BrowserStyle.body
        label.widthAnchor.constraint(equalToConstant:98).isActive = true
        value.font = BrowserStyle.body; value.setAccessibilityLabel(title+"检测结果")
        value.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let row = NSStackView(views:[label,value]); row.alignment = .firstBaseline; row.spacing = 12; addFull(row)
    }
    @objc func runCheck() {
        report = nil; runButton.isEnabled = false; copyButton.isEnabled = false
        runButton.title = "正在检测…"; outcome.stringValue = "正在检测本机图形能力…"
        for field in [device,webgl,webgl2,webgpu,decoder] { field.stringValue = "检测中…" }
        diagnostics.run { [weak self] value in self?.display(value) }
    }
    private func display(_ value:GraphicsReport) {
        report = value
        device.stringValue = value.devices.isEmpty ? "未检测到 Metal 设备" : value.devices.map(\.name).joined(separator:"、")
        func summary(_ check:GraphicsCheck)->String {
            let renderer = check.renderer.map { " · "+$0 } ?? ""
            return check.summary+renderer
        }
        webgl.stringValue = summary(value.webgl); webgl2.stringValue = summary(value.webgl2); webgpu.stringValue = summary(value.webgpu)
        webgl.toolTip = value.webgl.detail; webgl2.toolTip = value.webgl2.detail; webgpu.toolTip = value.webgpu.detail
        decoder.stringValue = value.decoders.map { $0.codec+($0.hardwareSupported ? " 支持" : " 不支持") }.joined(separator:" · ")
        let date = DateFormatter.localizedString(from:value.sampledAt,dateStyle:.short,timeStyle:.short)
        let checks = [value.webgl,value.webgl2,value.webgpu]
        outcome.stringValue = value.error ?? (checks.contains { $0.status == .failed || $0.status == .unknown } ? "检测结束 · 存在未通过或未确认项目，可复制报告查看详情。" : "检测完成 · \(date)。结果仅代表本次本地测试。")
        runButton.title = "重新检测"; runButton.isEnabled = true; copyButton.isEnabled = value.json != nil
    }
    func cancel() {
        let wasRunning = !runButton.isEnabled
        diagnostics.cancel()
        if wasRunning {
            runButton.isEnabled = true; runButton.title = "重新检测"
            for field in [device,webgl,webgl2,webgpu,decoder] { field.stringValue = "未完成" }
            outcome.stringValue = "检测已停止。点击重新检测获取结果。"
        }
    }
    @objc func copyReport() {
        guard let json = report?.json else { return }
        let pasteboard = CaptureClipboard.current
        pasteboard.clearContents()
        outcome.stringValue = pasteboard.setString(json,forType:.string) ? "诊断报告已复制。" : "无法复制诊断报告，请重试。"
    }
}
