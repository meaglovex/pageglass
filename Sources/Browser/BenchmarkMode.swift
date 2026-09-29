import AppKit
import CoreGraphics
import WebKit

/// Explicit local QA mode. It never restores user tabs or writes to the normal browser store.
@MainActor
enum BenchmarkMode {
    struct Plan:Decodable { let urls:[URL]; let output:URL; let websiteDataID:UUID }
    nonisolated static var enabled:Bool { CommandLine.arguments.contains("--benchmark-plan") }
    static func run(path:String,delegate:AppDelegate) async {
        var output:URL?
        do {
            let plan = try JSONDecoder().decode(Plan.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
            output = plan.output
            guard !plan.urls.isEmpty,plan.urls.count <= 10,plan.urls.allSatisfy({ $0.scheme == "http" && ["127.0.0.1","localhost"].contains($0.host ?? "") }) else { throw CaptureService.Failure.message("benchmark URLs must be explicit loopback fixtures (1–10 tabs)") }
            let session = CGSessionCopyCurrentDictionary() as? [String:Any]
            guard session != nil,session?["CGSSessionScreenIsLocked"] as? Bool != true else { throw CaptureService.Failure.message("benchmark requires an unlocked desktop") }
            let store = BrowserStore(directory:plan.output.appendingPathComponent("browser-data"))
            delegate.isolatedStore = store
            let tabs = SavedWindow(tabs:plan.urls.map{SavedTab(url:$0.absoluteString,title:"Benchmark")},active:0)
            let window = BrowserWindow(store:store,session:tabs,dataStore:WKWebsiteDataStore(forIdentifier:plan.websiteDataID))
            delegate.windows.append(window); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            for index in window.tabs.indices {
                window.activate(index)
                for _ in 0..<300 {
                    try await Task.sleep(for:.milliseconds(100))
                    if !window.webView.isLoading,window.webView.url == plan.urls[index] { break }
                }
                guard !window.webView.isLoading,window.webView.url == plan.urls[index] else { throw CaptureService.Failure.message("benchmark fixture did not load") }
            }
            window.activate(0)
            let state:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"tabs":window.tabs.count,"liveWebViews":window.tabs.filter{$0.webView != nil}.count,"viewport":["width":window.webView.bounds.width,"height":window.webView.bounds.height],"websiteDataID":plan.websiteDataID.uuidString,"status":"ready"]
            try FileManager.default.createDirectory(at:plan.output,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:state,options:.prettyPrinted).write(to:plan.output.appendingPathComponent("native-state.json"),options:.atomic)
        } catch {
            if let output,let data = try? JSONSerialization.data(withJSONObject:["status":"failed","error":error.localizedDescription]) { try? data.write(to:output.appendingPathComponent("native-error.json"),options:.atomic) }
            fputs("BENCHMARK NOT RUN: \(error.localizedDescription)\n",stderr); exit(2)
        }
    }
}
