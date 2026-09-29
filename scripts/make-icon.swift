// Reproducible geometric app icon. Run: swift scripts/make-icon.swift
import AppKit
let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
func color(_ hex:UInt32)->NSColor { NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1) }
func draw() {
    func rectangle(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ radius:CGFloat,_ hex:UInt32) {
        color(hex).setFill();NSBezierPath(roundedRect:NSRect(x:x,y:1024-y-h,width:w,height:h),xRadius:radius,yRadius:radius).fill()
    }
    rectangle(64,64,896,896,200,0x163A3A)
    rectangle(360,224,424,524,64,0x70CDB5)
    rectangle(224,328,424,472,64,0xF3F8F3)
    rectangle(280,408,224,24,12,0x163A3A)
    rectangle(280,472,152,24,12,0x91B3AA)
    let corner = NSBezierPath();corner.move(to:NSPoint(x:504,y:408));corner.line(to:NSPoint(x:584,y:408));corner.line(to:NSPoint(x:584,y:328));corner.lineWidth=24;corner.lineCapStyle = .round;corner.lineJoinStyle = .round;color(0x268773).setStroke();corner.stroke()
}
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        let transform = NSAffineTransform();transform.scale(by:CGFloat(pixels)/1024);transform.concat();draw();NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using:.png,properties:[:])!
        try data.write(to:iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
        if pixels == 1024 { try data.write(to:root.appendingPathComponent("assets/AppIcon.png")) }
        if size == 128 && scale == 1 { try data.write(to:root.appendingPathComponent("Sources/Browser/Resources/app-icon.png")) }
    }
}
let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil");process.arguments = ["-c","icns",iconset.path,"-o",root.appendingPathComponent("assets/AppIcon.icns").path];try process.run();process.waitUntilExit();if process.terminationStatus != 0 { exit(process.terminationStatus) }
