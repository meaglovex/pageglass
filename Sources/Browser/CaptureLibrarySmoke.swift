import AppKit

@MainActor
enum CaptureLibrarySmoke {
    static func run(_ browser:BrowserWindow,output:URL) async throws->[String] {
        var checks:[String] = []
        func require(_ value:Bool,_ label:String) throws { if !value { throw CaptureService.Failure.message(label) }; checks.append(label) }
        let fm = FileManager.default, root = browser.captureRoot
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let image = Resources.bundle.url(forResource:"app-icon",withExtension:"png",subdirectory:"Resources")!
        let raster = try Data(contentsOf:image)
        var packages:[URL] = []
        for index in 0..<200 {
            let directory = root.appendingPathComponent("\(Int(Date().timeIntervalSince1970)-1000+index)-\(UUID().uuidString.prefix(8))",isDirectory:true)
            try fm.createDirectory(at:directory,withIntermediateDirectories:false)
            let metadata:[String:Any] = ["title":"History fixture \(index)","url":"https://example.test/history/\(index)","mode":"element","warnings":["Synthetic legacy capture"]]
            try JSONSerialization.data(withJSONObject:metadata).write(to:directory.appendingPathComponent("capture.json"))
            try raster.write(to:directory.appendingPathComponent("screenshot.png"))
            try "<!doctype html><p>Owned legacy fixture</p>".write(to:directory.appendingPathComponent("reference.html"),atomically:true,encoding:.utf8)
            try "Local fixture: \(directory.path)".write(to:directory.appendingPathComponent("PROMPT.txt"),atomically:true,encoding:.utf8)
            packages.append(directory)
        }
        let expected = try CaptureRetention(root:root).packages().count
        var edited = CaptureEdits(); edited.name = "备注检索样本"; edited.notes = "筛选工作流专用备注"
        try edited.save(in:packages[199],expectedRevision:nil)
        let controller = CaptureLibraryController(browser:browser); controller.showWindow(nil); controller.refresh()
        defer { controller.close() }
        let started = Date()
        for _ in 0..<200 { if controller.records.count == expected { break }; try await Task.sleep(for:.milliseconds(25)) }
        try require(controller.records.count == expected && controller.table.numberOfRows == expected,"history loads 200 real-image legacy fixtures through its asynchronous list")
        let scanSeconds = Date().timeIntervalSince(started)
        if let capturedPage = try CaptureCatalog.scan(output).first(where: { $0.mode == "page" && $0.problem == nil }) {
            controller.detail.show(packages[0])
            try await Task.sleep(for:.milliseconds(300)); controller.window?.contentView?.layoutSubtreeIfNeeded()
            let divider = controller.detail.frame.minX
            controller.detail.show(capturedPage.directory)
            try await Task.sleep(for:.milliseconds(300)); controller.window?.contentView?.layoutSubtreeIfNeeded()
            try require(abs(controller.detail.frame.minX-divider) < 1,"changing between icon and page captures preserves the history divider position")
        } else { throw CaptureService.Failure.message("history layout check requires a real page capture") }
        controller.search.stringValue = "example.test/history/199"; controller.filter()
        try require(controller.filtered.count == 1 && controller.filtered[0].directory == packages[199],"history searches source URLs and selects the matching capture")
        controller.search.stringValue = "工作流专用备注"; controller.filter()
        try require(controller.filtered.count == 1 && controller.filtered[0].title == "备注检索样本","history searches saved notes among 200 capture records")
        controller.scope.selectItem(at:2); controller.filter(); try require(controller.filtered.isEmpty,"history type filter excludes element captures when whole-page is selected")
        controller.scope.selectItem(at:1); controller.period.selectItem(at:2); controller.filter()
        try require(controller.filtered.count == 1,"history combines note search type and date filters")
        controller.scope.selectItem(at:0); controller.period.selectItem(at:0)
        try CaptureCatalog.copyPrompt(packages[199])
        try require(CaptureClipboard.current.string(forType:.string)?.contains(packages[199].path) == true,"legacy capture is reusable after reopening history")
        controller.search.stringValue = ""; controller.filter()
        controller.table.scrollRowToVisible(expected-1)
        try await Task.sleep(for:.milliseconds(300))
        try require(CaptureCatalog.thumbnail(packages[199],pixels:128) != nil,"history decodes legacy PNG thumbnails")
        let external = packages[199]
        try fm.removeItem(at:external) // Only this run's disposable synthetic fixture.
        for _ in 0..<200 { if !controller.records.contains(where:{$0.directory == external}) { break }; try await Task.sleep(for:.milliseconds(25)) }
        try require(!controller.records.contains(where:{$0.directory == external}),"directory watcher removes an externally deleted capture from history")
        var rejected = false
        do { try CaptureCatalog.copyPrompt(external) } catch { rejected = true }
        try require(rejected,"external deletion cannot copy a stale capture path")
        var trashed:[URL:URL] = [:]
        let selected = Array(packages.prefix(2))
        let report = CaptureRetention(root:root).remove(selected) { original in
            var destination:NSURL?
            try fm.trashItem(at:original,resultingItemURL:&destination)
            if let destination { trashed[original] = destination as URL }
        }
        try require(report.removed.count == 2 && report.failures == 0 && fm.fileExists(atPath:packages[2].path),"selected cleanup uses real Trash and leaves other captures intact")
        for (original,trash) in trashed { try fm.moveItem(at:trash,to:original) }
        try require(selected.allSatisfy { CaptureCatalog.record($0).problem == nil },"trashed captures can be restored and read again")
        controller.close()
        let reopened = CaptureLibraryController(browser:browser); reopened.showWindow(nil); reopened.refresh()
        defer { reopened.close() }
        for _ in 0..<200 { if reopened.records.count == expected-1 { break }; try await Task.sleep(for:.milliseconds(25)) }
        try require(reopened.records.count == expected-1,"reopening history restores all remaining records from disk")
        try JSONSerialization.data(withJSONObject:["records":expected,"scanSeconds":scanSeconds,"scope":"component-level list, search, watcher and filesystem verification; not a manual scrolling benchmark"],options:.prettyPrinted).write(to:output.appendingPathComponent("capture-library-report.json"))
        return checks
    }
}
