// Isolated release microbenchmark. Compiled with actual source files by hotpaths.py.
// Measures specific native work, not browser-wide speed, input latency or GPU frames.
import AppKit
import CryptoKit
import ImageIO
import Darwin

@main
struct HotPathsProbe {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1]
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var result:[String:Any] = ["mode":mode]
        if mode == "search" {
            let root = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var state = BrowserStore.State()
            state.bookmarks = (0..<20).map { index in PageRecord(title:"产品书签 \(index)",url:"https://example.test/bookmark/\(index)",date:Date(timeIntervalSince1970:0)) }
            state.history = (0..<10000).map { index in PageRecord(title:String(format:"产品历史 item-%05d",index),url:"https://example.test/history/\(index)",date:Date(timeIntervalSince1970:0)) }
            try JSONEncoder().encode(state).write(to:root.appendingPathComponent("browser.json"))
            let store = BrowserStore(directory:root)
            var queries:[[String:Any]] = []
            for query in ["产品","item-09995","no-match-query"] {
                for _ in 0..<5 { _ = store.suggestions(query) }
                let start = ProcessInfo.processInfo.systemUptime
                var checksum = 0
                for _ in 0..<100 { checksum += autoreleasepool { store.suggestions(query).reduce(0) { $0+$1.url.utf8.count } } }
                let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
                queries.append(["query":query,"iterations":100,"millisecondsPerQuery":elapsed/100,"checksum":checksum,"urls":store.suggestions(query).map(\.url)])
            }
            result["queries"] = queries; result["records"] = 10020
        } else if mode == "tabs" {
            let tabs = (0..<100).map { i in let tab = BrowserTab(url:URL(string:"https://example.test/\(i)"));tab.title = "\(i) · 产品需求分析与长标题标签"; return tab }
            let buttons = tabs.map(TabButton.init)
            for (i,button) in buttons.enumerated() { button.update(tabs[i],selected:i == 0) }
            let start = ProcessInfo.processInfo.systemUptime
            for iteration in 0..<200 {
                autoreleasepool { for (i,button) in buttons.enumerated() { button.update(tabs[i],selected:i == iteration%100) } }
            }
            result["millisecondsPer100TabRefresh"] = (ProcessInfo.processInfo.systemUptime-start)*1000/200
            result["iterations"] = 200;result["tabs"] = 100
            result["selected"] = buttons.enumerated().filter { $0.element.selected }.map(\.offset)
            result["firstTitle"] = buttons[0].accessibilityLabel() ?? ""
        } else if mode == "png" {
            let width = 1440,height = 12000
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let bytes = bitmap.bitmapData else { fatalError("bitmap allocation failed") }
            for y in 0..<height { for x in 0..<width {
                let p = y*bitmap.bytesPerRow+x*4
                bytes[p] = UInt8((x/20)%256);bytes[p+1] = UInt8((y/20)%256);bytes[p+2] = UInt8((x/80+y/80)%2*180+40);bytes[p+3] = 255
            } }
            let image = NSImage(size:NSSize(width:width,height:height));image.addRepresentation(bitmap)
            var times:[Double] = [],latencies:[Double] = [],png:Data?
            // A fresh process encodes one image; avoid accumulating autoreleased
            // legacy intermediates across several operations in a CLI run loop.
            for _ in 0..<1 {
                let start = ProcessInfo.processInfo.systemUptime
                let encode = Task { @MainActor in try await CapturePNG.encode(image) }
                let heartbeat = Task { @MainActor in (ProcessInfo.processInfo.systemUptime-start)*1000 }
                png = try await encode.value
                times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                latencies.append(await heartbeat.value)
            }
            var usage = rusage(); guard getrusage(RUSAGE_SELF,&usage)==0,let png else { fatalError("missing encoding metrics") }
            // Record RSS before verification allocates its own decoded raster.
            result["peakRSSBytesBeforeVerification"] = usage.ru_maxrss
            guard let source = CGImageSourceCreateWithData(png as CFData,nil),let decoded = CGImageSourceCreateImageAtIndex(source,0,nil),
                  let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let pixels = context.data else { fatalError("PNG validation failed") }
            context.draw(decoded,in:CGRect(x:0,y:0,width:width,height:height))
            result["pixelSHA256"] = SHA256.hash(data:Data(bytesNoCopy:pixels,count:width*height*4,deallocator:.none)).map { String(format:"%02x",$0) }.joined()
            guard let reopened = NSImage(data:png) else { fatalError("PNG could not reopen") }
            result["logicalWidth"] = reopened.size.width; result["logicalHeight"] = reopened.size.height
            result["width"] = decoded.width;result["height"] = decoded.height;result["pngBytes"] = png.count
            result["encodeMilliseconds"] = times;result["mainActorSchedulingMilliseconds"] = latencies
        } else { fatalError("unknown workload") }
        let data = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
