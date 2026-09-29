import AppKit

extension BrowserWindow {
    func buildCaptureBar() {
        captureBar.spacing = 10; captureBar.edgeInsets = NSEdgeInsets(top:8,left:14,bottom:8,right:14)
        captureLabel.font = .systemFont(ofSize:12); captureLabel.lineBreakMode = .byTruncatingMiddle
        captureLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        cancelCaptureButton.title = "取消"; cancelCaptureButton.bezelStyle = .rounded
        cancelCaptureButton.target = self; cancelCaptureButton.action = #selector(cancelCapture)
        captureBar.addArrangedSubview(captureLabel); captureBar.addArrangedSubview(cancelCaptureButton); captureBar.isHidden = true
    }
    func syncCaptureBar() {
        let recorder = interactionRecording, count = max(0,(recorder?.frames.count ?? 0)-1)
        captureBar.isHidden = !capturing && !selecting && recorder?.isRecording != true && (recordingBarHidden || recorder?.frames.isEmpty != false)
        cancelCaptureButton.isEnabled = captureTask?.isCancelled != true
        if capturing { captureLabel.stringValue = captureTask?.isCancelled == true ? "正在取消并恢复页面…" : captureProgress; cancelCaptureButton.title = "取消捕获" }
        else if selecting { captureLabel.stringValue = selectionDescription.isEmpty ? "选取元素可见区域 · ↑ 父级 / ↓ 子级 · Enter 确认 · Esc 取消" : selectionDescription; cancelCaptureButton.title = "取消选取" }
        else if recorder?.isRecording == true { captureLabel.stringValue = "正在记录交互 · \(count) / 8 次 · 再次点击停止"; cancelCaptureButton.title = "停止记录" }
        else { captureLabel.stringValue = count >= 8 ? "已达到 8 次操作上限，记录已停止 · 下次捕获会一起保存" : "记录已停止 · \(count) 次操作 · 下次捕获会一起保存"; cancelCaptureButton.title = "隐藏" }
    }
    @objc func cancelCapture() {
        if capturing {
            captureTask?.cancel()
            activeWebView?.evaluateJavaScript("globalThis.__pageglassAbortAssets?.();globalThis.__pageglass?.finish()",in:nil,in:CaptureService.world)
        } else if selecting {
            selecting = false; activeWebView?.evaluateJavaScript("globalThis.__pageglass?.stop()",in:nil,in:CaptureService.world)
        } else if interactionRecording?.isRecording == true { toggleInteractionRecording() }
        else { recordingBarHidden = true }
        syncChrome()
    }
    func showCaptureResult(_ result:CaptureResult) {
        captureResultController?.close()
        captureResultController = CapturePreviewController(browser:self,directory:result.directory)
        captureResultController?.showWindow(nil)
        captureResultController?.window?.makeKeyAndOrderFront(nil)
    }
}
