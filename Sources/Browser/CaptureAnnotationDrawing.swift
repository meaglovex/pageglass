import AppKit
import ImageIO

enum CaptureAnnotationDrawing {
    static func image(in directory:URL) throws->NSImage {
        try CaptureCatalog.validate(directory)
        let url = try CaptureCatalog.file("screenshot.png",in:directory)
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let raster = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CaptureEdits.Failure.message("无法读取原截图") }
        return NSImage(cgImage:raster,size:NSSize(width:raster.width,height:raster.height))
    }
    static func color(_ value:CaptureAnnotation.Color)->NSColor {
        switch value { case .red:return NSColor(srgbRed:0.87,green:0.12,blue:0.18,alpha:1)
        case .blue:return NSColor(srgbRed:0.06,green:0.34,blue:0.9,alpha:1)
        case .amber:return NSColor(srgbRed:0.61,green:0.31,blue:0.02,alpha:1) }
    }
    static func rect(_ mark:CaptureAnnotation,size:NSSize)->NSRect {
        if mark.kind == .rectangle || mark.kind == .arrow {
            return NSRect(x:mark.bounds.minX*size.width,y:mark.bounds.minY*size.height,width:mark.bounds.width*size.width,height:mark.bounds.height*size.height)
        }
        return NSRect(x:mark.x*size.width,y:mark.y*size.height,width:mark.kind == .number ? 30 : max(40,min(360,size.width-mark.x*size.width)),height:mark.kind == .number ? 30 : 100)
    }
    /// Both the editor and PNG export draw in image pixels, with a top-left origin.
    static func draw(_ marks:[CaptureAnnotation],size:NSSize) {
        for mark in marks {
            let ink = color(mark.color), a = NSPoint(x:mark.x*size.width,y:mark.y*size.height), b = NSPoint(x:mark.endX*size.width,y:mark.endY*size.height)
            ink.setStroke(); ink.setFill()
            switch mark.kind {
            case .rectangle:
                let path = NSBezierPath(rect:rect(mark,size:size)); path.lineWidth = 3; path.stroke()
            case .arrow:
                let angle = atan2(b.y-a.y,b.x-a.x), length = min(14,hypot(b.x-a.x,b.y-a.y)*0.4)
                let path = NSBezierPath(); path.lineWidth = 3; path.lineCapStyle = .round
                path.move(to:a); path.line(to:b)
                for offset in [-0.5,0.5] { path.move(to:b); path.line(to:NSPoint(x:b.x-length*cos(angle+offset),y:b.y-length*sin(angle+offset))) }
                path.stroke()
            case .number:
                let circle = NSRect(origin:a,size:NSSize(width:30,height:30)); NSBezierPath(ovalIn:circle).fill()
                let text = String(mark.text.prefix(3)) as NSString, attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:17,weight:.bold),.foregroundColor:NSColor.white]
                let measured = text.size(withAttributes:attributes)
                text.draw(at:NSPoint(x:circle.midX-measured.width/2,y:circle.midY-measured.height/2),withAttributes:attributes)
            case .text:
                let box = rect(mark,size:size), style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
                let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:20,weight:.semibold),.foregroundColor:ink,.paragraphStyle:style,.backgroundColor:NSColor.white.withAlphaComponent(0.9)]
                (mark.text as NSString).draw(with:box,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes)
            }
        }
    }
    static func png(image:NSImage,marks:[CaptureAnnotation]) throws->Data {
        var edits = CaptureEdits(); edits.annotations = marks; try edits.validate()
        let size = image.size
        guard size.width > 0,size.height > 0,size.width <= 32000,size.height <= 32000,size.width*size.height <= 32_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width),pixelsHigh:Int(size.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw CaptureEdits.Failure.message("截图尺寸超限或无法创建标注图片") }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext; cg.translateBy(x:0,y:size.height); cg.scaleBy(x:1,y:-1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:cg,flipped:true)
        image.draw(in:NSRect(origin:.zero,size:size),from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        draw(marks,size:size)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw CaptureEdits.Failure.message("无法生成标注图片") }
        return data
    }
}

final class CaptureAnnotationCanvas:NSView {
    var image:NSImage?
    var marks:[CaptureAnnotation] = [] { didSet { needsDisplay = true } }
    var selected:UUID? { didSet { needsDisplay = true; selectionChanged?() } }
    var tool:CaptureAnnotation.Kind?
    var ink:CaptureAnnotation.Color = .red
    var selectionChanged:(()->Void)?
    var commit:(([CaptureAnnotation],String)->Void)?
    private var start:NSPoint?, initial:[CaptureAnnotation] = [], pending:CaptureAnnotation?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.white.setFill(); bounds.fill()
        guard let image else { return }
        image.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(scale:bounds.width/image.size.width); (transform as NSAffineTransform).concat()
        CaptureAnnotationDrawing.draw(marks+(pending.map { [$0] } ?? []),size:image.size)
        if let mark = marks.first(where:{$0.id == selected}) {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect:CaptureAnnotationDrawing.rect(mark,size:image.size).insetBy(dx:-4,dy:-4))
            outline.lineWidth = max(1,image.size.width/bounds.width); outline.setLineDash([4,3],count:2,phase:0); outline.stroke()
        }
    }
    private func point(_ event:NSEvent)->NSPoint {
        let p = convert(event.locationInWindow,from:nil)
        return NSPoint(x:max(0,min(1,p.x/bounds.width)),y:max(0,min(1,p.y/bounds.height)))
    }
    override func mouseDown(with event:NSEvent) {
        guard image != nil else { return }
        window?.makeFirstResponder(self)
        let p = point(event); start = p; initial = marks
        if let tool {
            selected = nil
            var mark = CaptureAnnotation(kind:tool,x:p.x,y:p.y,endX:p.x,endY:p.y,color:ink)
            if tool == .number { mark.text = String((marks.filter{$0.kind == .number}.compactMap{Int($0.text)}.max() ?? 0)+1) }
            if tool == .text { mark.text = "请输入文字" }
            pending = mark; needsDisplay = true
        } else {
            let pixels = NSPoint(x:p.x*image!.size.width,y:p.y*image!.size.height)
            selected = marks.reversed().first { CaptureAnnotationDrawing.rect($0,size:image!.size).insetBy(dx:-8,dy:-8).contains(pixels) }?.id
        }
    }
    override func mouseDragged(with event:NSEvent) {
        guard let start else { return }; let p = point(event)
        if pending != nil {
            if tool == .rectangle || tool == .arrow { pending?.endX = p.x; pending?.endY = p.y }
        } else if let selected { marks = initial.map { $0.id == selected ? $0.moved(dx:p.x-start.x,dy:p.y-start.y) : $0 } }
        needsDisplay = true
    }
    override func mouseUp(with event:NSEvent) {
        guard start != nil else { return }; mouseDragged(with:event); start = nil
        if let pending {
            self.pending = nil
            if pending.kind == .text || pending.kind == .number || abs(pending.x-pending.endX)+abs(pending.y-pending.endY) > 0.003 {
                commit?(initial+[pending],"添加标注"); selected = pending.id
            }
        } else if marks != initial { let result = marks; marks = initial; commit?(result,"移动标注") }
        needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 { if start != nil { marks = initial }; pending = nil; start = nil; selected = nil; needsDisplay = true; return }
        guard let selected else { super.keyDown(with:event); return }
        if [51,117].contains(event.keyCode) { commit?(marks.filter{$0.id != selected},"删除标注"); self.selected = nil; return }
        if let size = image?.size,[123,124,125,126].contains(event.keyCode) {
            let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let dx = event.keyCode == 123 ? -step/size.width : event.keyCode == 124 ? step/size.width : 0
            let dy = event.keyCode == 126 ? -step/size.height : event.keyCode == 125 ? step/size.height : 0
            commit?(marks.map { $0.id == selected ? $0.moved(dx:dx,dy:dy) : $0 },"移动标注"); return
        }
        super.keyDown(with:event)
    }
}
