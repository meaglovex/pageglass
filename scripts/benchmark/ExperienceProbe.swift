// Added only to an isolated benchmark build by experience.py; not part of the shipped app.
import AppKit
import WebKit

@MainActor
enum ExperienceProbe {
    struct Plan: Decodable { let output: URL; let fixture: URL; let websiteDataID: UUID }
    final class WeakView { weak var value: WKWebView?; init(_ view: WKWebView?) { value = view } }

    static func write(_ value: [String: Any], _ name: String, _ root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
    }
    static func checkpoint(_ name: String, root: URL) async throws {
        try write(["phase": name, "time": Date().timeIntervalSince1970], "checkpoint", root)
        let acknowledgement = root.appendingPathComponent(name + ".ack")
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: acknowledgement.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CaptureService.Failure.message("benchmark checkpoint timeout: " + name)
    }
    static func script(_ view: WKWebView, _ source: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }
    static func frames(_ view: WKWebView) async throws {
        _ = try await script(view,
            "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true;")
    }
    static func loaded(_ browser: BrowserWindow) async throws {
        for _ in 0..<300 {
            if !browser.webView.isLoading, browser.webView.title == "Pageglass experience fixture" {
                try await frames(browser.webView); return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CaptureService.Failure.message("experience fixture did not finish loading")
    }
    static func capture(_ mode: String, browser: BrowserWindow, root: URL) async throws -> [String: Any] {
        _ = try await browser.webView.evaluateJavaScript("window.scrollTo(0,0)")
        try await frames(browser.webView)
        if mode == "element" {
            _ = try await browser.captureService.js(browser.webView, "globalThis.__pageglass.selectForTest('#metric-card')")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await browser.captureService.capture(browser.webView, mode: mode,
            destination: root.appendingPathComponent("captures")) { _ in }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        for name in ["capture.json", "reference.html", "screenshot.png"] {
            guard let size = (try FileManager.default.attributesOfItem(atPath: result.directory.appendingPathComponent(name).path))[.size] as? NSNumber,
                  size.intValue > 0 else { throw CaptureService.Failure.message("missing capture file: " + name) }
        }
        // Match normal latest-result ownership, including the retained raster in 0.6.
        browser.latest = result
        return ["milliseconds": milliseconds, "directory": result.directory.path,
                "nodeCount": result.metadata["nodeCount"] ?? 0,
                "screenshot": result.metadata["screenshot"] ?? [:],
                "warnings": result.metadata["warnings"] ?? []]
    }
    static func run(path: String, delegate: AppDelegate) async {
        var root: URL?
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let temporary = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path + "/"
            let outputPath = plan.output.resolvingSymlinksInPath().path
            guard plan.output.isFileURL, outputPath.hasPrefix(temporary),
                  plan.fixture.isFileURL, plan.fixture.resolvingSymlinksInPath().path.hasPrefix(outputPath + "/") else {
                throw CaptureService.Failure.message("probe accepts only its own temporary fixture and output")
            }
            root = plan.output
            let browser = BrowserWindow(store: BrowserStore(directory: plan.output.appendingPathComponent("browser-data")),
                session: SavedWindow(tabs: [SavedTab(url: plan.fixture.absoluteString, title: "Benchmark")], active: 0),
                dataStore: WKWebsiteDataStore(forIdentifier: plan.websiteDataID))
            delegate.windows.append(browser)
            browser.window?.appearance = NSAppearance(named: .aqua)
            browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<200 {
                if NSApp.isActive, browser.window?.isKeyWindow == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            browser.focusAddress()
            await Task.yield()
            guard NSApp.isActive, browser.window?.isKeyWindow == true,
                  browser.window?.isVisible == true, browser.address.isEditable, browser.address.isEnabled,
                  let editor = browser.address.currentEditor(), browser.window?.firstResponder === editor else {
                throw CaptureService.Failure.message("address editor is not ready")
            }
            try write(["pid": ProcessInfo.processInfo.processIdentifier,
                       "addressReadyAt": Date().timeIntervalSince1970,
                       "screenMaximumFPS": browser.window?.screen?.maximumFramesPerSecond ?? 0], "startup", plan.output)
            try await loaded(browser)
            for index in 1..<10 {
                var url = URLComponents(url: plan.fixture, resolvingAgainstBaseURL: false)!
                url.fragment = "tab-\(index)"
                browser.openTab(url.url!); try await loaded(browser)
            }
            browser.activate(0); try await frames(browser.webView)
            let viewport: [String: Any] = ["width": browser.webView.bounds.width, "height": browser.webView.bounds.height]
            // One sleeping task: no in-app polling during the idle CPU sample.
            try write(["phase": "idle", "time": Date().timeIntervalSince1970], "checkpoint", plan.output)
            try await Task.sleep(for: .seconds(20))
            try await checkpoint("loaded", root: plan.output)
            var switches: [[String: Any]] = []
            for index in (1...30).map({ $0 % 10 }) {
                let started = ProcessInfo.processInfo.systemUptime
                browser.activate(index)
                browser.window?.contentView?.layoutSubtreeIfNeeded()
                try await frames(browser.webView)
                guard browser.activeIndex == index else { throw CaptureService.Failure.message("tab did not activate") }
                switches.append(["target": index, "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            }
            let scroll = try await script(browser.webView, """
                return await new Promise(resolve => {
                    const intervals = []; let first, last;
                    window.scrollTo(0, 0);
                    function frame(now) {
                        first ??= now;
                        if (last !== undefined) intervals.push(now - last);
                        last = now; const elapsed = now - first;
                        window.scrollTo(0, elapsed * 1.5);
                        if (elapsed < 4000) requestAnimationFrame(frame);
                        else resolve({intervalsMilliseconds: intervals, scrollY, elapsedMilliseconds: elapsed,
                            viewport: {width: innerWidth, height: innerHeight}, documentHeight: document.documentElement.scrollHeight});
                    }
                    requestAnimationFrame(frame);
                });
                """)
            guard let scrolling = scroll as? [String: Any],
                  let intervals = scrolling["intervalsMilliseconds"] as? [Double], intervals.count > 60,
                  (scrolling["scrollY"] as? Double ?? 0) > 5000 else {
                throw CaptureService.Failure.message("scroll workload did not complete")
            }
            try await checkpoint("before-capture", root: plan.output)
            let element = try await capture("element", browser: browser, root: plan.output)
            try await checkpoint("after-element", root: plan.output)
            let page = try await capture("page", browser: browser, root: plan.output)
            try await checkpoint("after-page", root: plan.output)
            browser.latest = nil
            let closedViews = browser.tabs.dropFirst().map { WeakView($0.webView) }
            while browser.tabs.count > 1 { browser.close(at: browser.tabs.count - 1) }
            browser.activate(0)
            try await Task.sleep(for: .seconds(5))
            let released = closedViews.allSatisfy { $0.value == nil }
            guard released else { throw CaptureService.Failure.message("a closed tab still retains its WebView") }
            try await checkpoint("released", root: plan.output)
            try write(["status": "completed", "viewport": viewport, "switches": switches,
                       "scroll": scroll, "elementCapture": element, "pageCapture": page,
                       "closedWebViewsReleased": released, "remainingTabs": browser.tabs.count,
                       "remainingWebViews": browser.tabs.filter { $0.webView != nil }.count], "experience", plan.output)
        } catch {
            if let root { try? write(["status": "failed", "error": error.localizedDescription], "experience", root) }
        }
    }
}
