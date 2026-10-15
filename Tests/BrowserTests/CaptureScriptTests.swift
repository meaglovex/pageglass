import XCTest
import WebKit
@testable import Browser

/// Runs the shipped capture.js in its isolated content world against an owned fixture.
/// Subresources point at a closed loopback port so loads fail at once without network access.
@MainActor
final class CaptureScriptTests:XCTestCase,WKNavigationDelegate,WKScriptMessageHandler {
    private var loaded:XCTestExpectation?
    private var messages:[[String:Any]] = []
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { loaded?.fulfill() }
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) { if let body = message.body as? [String:Any] { messages.append(body) } }

    private func page(_ html:String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self,contentWorld:CaptureService.world,name:"pageglass")
        configuration.userContentController.addUserScript(WKUserScript(source:CaptureService.script,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:CaptureService.world))
        let view = WKWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:configuration); view.navigationDelegate = self
        loaded = expectation(description:"fixture loaded")
        view.loadHTMLString(html,baseURL:URL(string:"http://127.0.0.1:9/"))
        await fulfillment(of:[loaded!],timeout:30)
        return view
    }
    private func run(_ view:WKWebView,_ source:String) async throws -> Any? { try await view.evaluateJavaScript(source,in:nil,contentWorld:CaptureService.world) }

    func testExportKeepsVoidElementsSingleAndResolvesEveryAssetToken() async throws {
        let images = (0..<14).map { "<img alt=\"i\($0)\" src=\"/image-\($0).png\">" }.joined()
        let view = try await page("<!doctype html><body><p id=lines>one<br>two<br>three</p><hr><input value=secret>\(images)<div style=\"background-image:url(/background.png)\">bg</div></body>")
        guard let data = try await run(view,"globalThis.__pageglass.extract('page')") as? [String:Any],let html = data["html"] as? String,let references = data["assetReferences"] as? [[String:String]] else { return XCTFail("extract returned no document") }
        XCTAssertFalse(html.contains("</br>") || html.contains("</img>") || html.contains("</input>") || html.contains("</hr>"))
        XCTAssertFalse(html.contains("secret"),"input values stay out of exported code")
        XCTAssertGreaterThanOrEqual(references.count,15)
        var paths:[String:String] = [:]
        for (index,reference) in references.enumerated() { paths[reference["url"]!] = "assets/resource-\(index).png" }
        let resolved = CaptureAssets.resolve(html,references:references,paths:paths)
        XCTAssertFalse(resolved.contains("pageglass_asset_"))
        for index in 0..<14 {
            guard let reference = references.firstIndex(where:{$0["url"] == "http://127.0.0.1:9/image-\(index).png"}) else { XCTFail("image \(index) was not referenced"); continue }
            XCTAssertTrue(resolved.contains("src=\"assets/resource-\(reference).png\""),"image \(index)")
        }

        let replay = try await page(resolved)
        let breaks = try await replay.evaluateJavaScript("document.querySelectorAll('br').length") as? Int
        XCTAssertEqual(breaks,2,"exported <br> elements parse back one-to-one")
    }

    func testSelectionClickDoesNotReachDocumentCaptureListeners() async throws {
        let view = try await page("<!doctype html><body><button id=target>Go</button><script>window.reached=[];document.addEventListener('click',()=>reached.push('document'),true);document.getElementById('target').addEventListener('click',()=>reached.push('target'))</script></body>")
        _ = try await run(view,"globalThis.__pageglass.start()")
        _ = try await view.evaluateJavaScript("document.getElementById('target').click()")
        let reached = try await view.evaluateJavaScript("window.reached.join(',')") as? String
        XCTAssertEqual(reached,"","page click handlers must not run while selecting")
        XCTAssertTrue(messages.contains { $0["type"] as? String == "selected" })
    }
}
