import AppKit
import WebKit

@MainActor
final class Verification:NSObject,NSApplicationDelegate {
    var window:NSWindow!,view:WKWebView!
    var report:[String:Any] = [:]
    let capture = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL
    func applicationDidFinishLaunching(_ notification:Notification) { Task { await run() } }
    func check(_ value:Bool,_ message:String) throws { if !value { throw NSError(domain:"PrototypeQA",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }
    func load(_ url:URL,width:Double,height:Double) async throws {
        window.setContentSize(NSSize(width:width,height:height));view.frame = NSRect(x:0,y:0,width:width,height:height)
        view.loadFileURL(url,allowingReadAccessTo:output)
        for _ in 0..<100 { try await Task.sleep(for:.milliseconds(100));if !view.isLoading,view.url == url { break } }
        try check(!view.isLoading && view.url == url,"local prototype failed to load: expected \(url.absoluteString), actual \(view.url?.absoluteString ?? "nil"), loading \(view.isLoading)")
        let _:Any? = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("await document.fonts.ready; return true",arguments:[:],in:nil,in:.defaultClient) { continuation.resume(with:$0) }
        }
    }
    func snapshot(_ name:String,width:Int? = nil,height:Int? = nil) async throws -> NSBitmapImageRep {
        let config = WKSnapshotConfiguration();config.rect=view.bounds;config.snapshotWidth=900;config.afterScreenUpdates=true
        let image = try await view.takeSnapshot(configuration:config)
        guard let tiff=image.tiffRepresentation,let original=NSBitmapImageRep(data:tiff) else { throw NSError(domain:"PNG",code:1) }
        let result:NSBitmapImageRep
        if let width,let height {
            result=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:result)
            image.draw(in:NSRect(x:0,y:0,width:width,height:height),from:.zero,operation:.copy,fraction:1)
            NSGraphicsContext.restoreGraphicsState()
        } else { result=original }
        try result.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
        return result
    }
    func compare(_ original:NSBitmapImageRep,_ copy:NSBitmapImageRep,_ name:String) throws {
        try check(original.pixelsWide == copy.pixelsWide && original.pixelsHigh == copy.pixelsHigh,"\(name): raster dimensions differ")
        var error=0.0,significant=0,pixels=0
        for y in stride(from:0,to:original.pixelsHigh,by:2) { for x in stride(from:0,to:original.pixelsWide,by:2) {
            guard let a=original.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),let b=copy.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
            let e=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)
            error += e;pixels += 1;if e/3 > 0.1 { significant += 1 }
        }}
        let mean=error/Double(max(pixels*3,1)),ratio=Double(significant)/Double(max(pixels,1))
        report[name] = ["meanAbsoluteRGBError":mean,"significantPixelRatio":ratio,"sampledPixels":pixels,"width":copy.pixelsWide,"height":copy.pixelsHigh]
        try check(pixels > 0 && mean < 0.01 && ratio < 0.02,"\(name): visual mismatch (mean \(mean), changed \(ratio))")
    }
    func run() async {
        do {
            let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:capture.appendingPathComponent("capture.json"))) as! [String:Any]
            let vp=metadata["viewport"] as! [String:Double],doc=metadata["document"] as! [String:Double]
            let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
            let rule=try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"pageglass-prototype-offline",encodedContentRuleList:"[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]")!
            configuration.userContentController.add(rule)
            view=WKWebView(frame:.zero,configuration:configuration)
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:vp["width"]!,height:doc["height"]!),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=view;window.orderFront(nil)
            let prototype=output.appendingPathComponent("prototype.html")
            let original=NSBitmapImageRep(data:try Data(contentsOf:capture.appendingPathComponent("screenshot.png")))!
            try await load(prototype,width:vp["width"]!,height:doc["height"]!)
            _ = try await view.evaluateJavaScript("document.querySelector('#prototype-details').style.visibility='hidden'")
            let base=try await snapshot("baseline.png",width:original.pixelsWide,height:original.pixelsHigh)
            try compare(original,base,"fullPageBaseline")
            _ = try await view.evaluateJavaScript("document.querySelector('#prototype-details').style.visibility=''")
            _ = try await snapshot("with-details-button.png",width:original.pixelsWide,height:original.pixelsHigh)
            let details=try await view.evaluateJavaScript("document.querySelector('#prototype-details').click();document.querySelector('#prototype-dialog').open") as? Bool
            try check(details == true,"new details button does not open dialog")
            _ = try await snapshot("details-dialog.png")
            let closed=try await view.evaluateJavaScript("document.querySelector('#prototype-close').click();!document.querySelector('#prototype-dialog').open") as? Bool
            try check(closed == true,"new details dialog does not close")
            let collapsed=try await view.evaluateJavaScript("document.querySelector('#new-request').click();({expanded:document.querySelector('#new-request').getAttribute('aria-expanded'),display:getComputedStyle(document.querySelector('#notice')).display})") as! [String:String]
            try check(collapsed["expanded"] == "false" && collapsed["display"] == "none","observed collapse behavior not reproduced")
            let expanded=try await view.evaluateJavaScript("document.querySelector('#new-request').click();({expanded:document.querySelector('#new-request').getAttribute('aria-expanded'),display:getComputedStyle(document.querySelector('#notice')).display})") as! [String:String]
            try check(expanded["expanded"] == "true" && expanded["display"] != "none","observed expand behavior not reproduced")
            let initialMetadata=try JSONSerialization.jsonObject(with:Data(contentsOf:capture.appendingPathComponent("interaction-history/state-00.json"))) as! [String:Any]
            let initialViewport=initialMetadata["viewport"] as! [String:Double]
            try await load(prototype,width:initialViewport["width"]!,height:initialViewport["height"]!)
            _ = try await view.evaluateJavaScript("document.querySelector('#prototype-details').style.visibility='hidden';document.querySelector('#new-request').click()")
            let collapsedImage=try await snapshot("observed-collapsed.png")
            let observed=NSBitmapImageRep(data:try Data(contentsOf:capture.appendingPathComponent("interaction-history/state-00.png")))!
            try compare(observed,collapsedImage,"observedCollapsedState")
            report["functionalChecks"]=["details opens","details closes","observed collapse","observed expand","network blocked"]
            report["status"]="passed"
        } catch { report["status"]="failed";report["error"]=error.localizedDescription }
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
        print(String(data:(try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? "")
        exit(report["status"] as? String == "passed" ? 0 : 1)
    }
}
MainActor.assumeIsolated {
let app=NSApplication.shared
let verification=Verification()
app.delegate=verification
app.setActivationPolicy(.accessory)
app.run()
}
