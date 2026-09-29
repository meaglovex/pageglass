import AppKit
import WebKit
import CryptoKit

@MainActor
enum CaptureEditingSmoke {
    static func run(_ browser:BrowserWindow,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ condition:Bool,_ label:String) throws { if !condition { throw CaptureEdits.Failure.message(label) }; checks.append(label) }
        guard let record = try CaptureCatalog.scan(output).first(where:{$0.problem == nil && $0.mode == "element"}) else { throw CaptureEdits.Failure.message("annotation smoke requires an actual element capture") }
        let directory = record.directory, originalNames = ["screenshot.png","capture.json","reference.html","PROMPT.txt"]
        let original = try originalNames.map { try Data(contentsOf:directory.appendingPathComponent($0)) }
        let editor = try CaptureEditorController(directory:directory); editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        defer { editor.close() }
        editor.window?.setContentSize(NSSize(width:900,height:528)); editor.window?.contentView?.layoutSubtreeIfNeeded()
        try require(editor.window?.contentView?.bounds.width == 900 && editor.canvas.bounds.width > 300 && editor.annotationText.enclosingScrollView != nil,"annotation editor fits 900 pt and scrolls its detail fields at minimum height")
        let marks = [CaptureAnnotation(kind:.rectangle,x:0.05,y:0.08,endX:0.8,endY:0.8),CaptureAnnotation(kind:.arrow,x:0.15,y:0.6,endX:0.7,endY:0.2,color:.blue),CaptureAnnotation(kind:.number,x:0.08,y:0.1,endX:0.08,endY:0.1,text:"1"),CaptureAnnotation(kind:.text,x:0.2,y:0.35,endX:0.2,endY:0.35,text:"新增查看详情",color:.amber)]
        editor.undo.beginUndoGrouping(); editor.setAnnotations(marks,action:"添加四种标注"); editor.undo.endUndoGrouping()
        try require(editor.edits.annotations.count == 4 && editor.dirty,"annotation editor accepts four editable shape types")
        editor.undoEdit(); try require(editor.edits.annotations.isEmpty,"annotation undo restores the preceding document")
        editor.redoEdit(); try require(editor.edits.annotations == marks,"annotation redo restores shape coordinates and text")
        editor.name.stringValue = "产品验收标注"; editor.notes.string = "在卡片右侧增加查看详情按钮"
        let saved = try editor.saveEdits()
        try require(!editor.dirty && CaptureCatalog.record(directory).title == "产品验收标注","save updates capture display metadata without leaving a false dirty state")
        let loaded = try CaptureEdits.load(in:directory)
        try require(loaded == saved,"reopening reads editable annotation data and notes from disk")
        try require(try originalNames.map { try Data(contentsOf:directory.appendingPathComponent($0)) } == original,"annotations and notes preserve the original PNG HTML JSON and prompt bytes")
        try CaptureCatalog.copyPrompt(directory)
        try require(CaptureClipboard.current.string(forType:.string)?.contains("在卡片右侧增加查看详情按钮") == true,"Codex copy includes saved user notes and the annotation sidecar reference")
        let png = try CaptureAnnotationDrawing.png(image:CaptureAnnotationDrawing.image(in:directory),marks:loaded.annotations)
        try png.write(to:output.appendingPathComponent("annotation-preview.png"))
        let raster = NSBitmapImageRep(data:png), sourceRaster = NSBitmapImageRep(data:original[0])
        try require(raster?.pixelsWide == sourceRaster?.pixelsWide && raster?.pixelsHigh == sourceRaster?.pixelsHigh && png != original[0],"annotated PNG retains original pixel dimensions and includes visible edits")

        // Exact corner colors and a top-left rectangle catch vertically mirrored exports.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:120,pixelsHigh:100,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let white = NSColor(deviceRed:1,green:1,blue:1,alpha:1), black = NSColor(deviceRed:0,green:0,blue:0,alpha:1)
        for y in 0..<100 { for x in 0..<120 { bitmap.setColor(y < 50 ? white : black,atX:x,y:y) } }
        let picture = NSImage(size:NSSize(width:120,height:100)); picture.addRepresentation(bitmap)
        let orientationPNG = try CaptureAnnotationDrawing.png(image:picture,marks:[CaptureAnnotation(kind:.rectangle,x:0.1,y:0.1,endX:0.4,endY:0.35)])
        let orientation = NSBitmapImageRep(data:orientationPNG)!
        let top = orientation.colorAt(x:100,y:10)!.usingColorSpace(.deviceRGB)!, bottom = orientation.colorAt(x:100,y:90)!.usingColorSpace(.deviceRGB)!, line = orientation.colorAt(x:12,y:20)!.usingColorSpace(.deviceRGB)!
        try orientationPNG.write(to:output.appendingPathComponent("annotation-orientation.png"))
        try JSONSerialization.data(withJSONObject:["top":[top.redComponent,top.greenComponent,top.blueComponent],"bottom":[bottom.redComponent,bottom.greenComponent,bottom.blueComponent],"line":[line.redComponent,line.greenComponent,line.blueComponent]],options:.prettyPrinted).write(to:output.appendingPathComponent("annotation-pixel-diagnostic.json"))
        try require(top.redComponent > 0.9 && bottom.redComponent < 0.1 && line.redComponent > 0.7 && line.greenComponent < 0.3,"annotation raster preserves top-left coordinates and original image orientation")

        let portable = output.appendingPathComponent("portable-capture"), moved = output.appendingPathComponent("portable-moved")
        try await Task.detached(priority:.userInitiated) { try CapturePortable.export(directory,to:portable,format:.folder) }.value
        try FileManager.default.moveItem(at:portable,to:moved)
        try require(CaptureCatalog.record(moved).problem == nil && FileManager.default.fileExists(atPath:moved.appendingPathComponent("annotated.png").path),"moved portable folder contains the original evidence and annotated PNG")
        let movedEdits = try CaptureEdits.load(in:moved)
        try require(movedEdits.annotations == loaded.annotations && movedEdits.notes == loaded.notes,"portable folder preserves editable marks and notes")
        let reference = try CaptureReferenceController(directory:moved); reference.showWindow(nil)
        defer { reference.close() }
        guard let web = reference.window?.contentView as? WKWebView else { throw CaptureEdits.Failure.message("portable reference web view missing") }
        for _ in 0..<100 { if !web.isLoading,web.url?.lastPathComponent == "reference.html" { break }; try await Task.sleep(for:.milliseconds(30)) }
        try require(!web.isLoading && web.url?.lastPathComponent == "reference.html" && !web.configuration.defaultWebpagePreferences.allowsContentJavaScript,"moved reference opens in a real WebKit preview with page scripts disabled")
        let protectedView = reference.window!.contentView!
        try require(protectedView.bounds.width > 0 && editor.canvas.frame.width > 0 && editor.canvas.frame.height > 0,"native annotation canvas and moved reference have nonzero visible layout")
        let report:[String:Any] = ["checks":checks,"sourcePNGHash":SHA256.hash(data:original[0]).map{String(format:"%02x",$0)}.joined(),"annotationPNGHash":SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined(),"scope":"Owned AppKit editor methods, offscreen PNG renderer, filesystem relocation, real WKWebView; physical mouse/keyboard and receiver import are separate acceptance gates."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("capture-editing-report.json"))
        return checks
    }
}
