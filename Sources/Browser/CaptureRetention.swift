import AppKit

/// Only direct, completed capture packages are eligible. Never follow symlinks or metadata paths.
struct CaptureRetention {
    static let changed = Notification.Name("PageglassCapturesChanged")
    let root: URL
    struct Report {
        var removed: [URL] = []
        var failures = 0
        var message: String { "已移入废纸篓 \(removed.count) 个捕获包" + (failures == 0 ? "" : "；\(failures) 个清理失败") }
    }
    func packages() throws -> [(url:URL,date:Date)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath:root.path) else { return [] }
        let rootValues = try root.resourceValues(forKeys:[.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else { return [] }
        return try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]).compactMap { url in
            guard url.lastPathComponent.range(of:"^[0-9]{10}-[A-Fa-f0-9]{8}$",options:.regularExpression) != nil,
                  let epoch = Double(url.lastPathComponent.prefix(10)),
                  let values = try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),
                  values.isDirectory == true,values.isSymbolicLink != true else { return nil }
            let manifest = url.appendingPathComponent("capture.json")
            guard let metadata = try? manifest.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),metadata.isRegularFile == true,metadata.isSymbolicLink != true else { return nil }
            return (url,Date(timeIntervalSince1970:epoch))
        }
    }
    func clean(days:Int,all:Bool = false,now:Date = Date(),move:(URL)throws->Void = { try FileManager.default.trashItem(at:$0,resultingItemURL:nil) }) -> Report {
        var report = Report()
        guard all || days > 0 else { return report }
        do {
            for package in try packages() where all || now.timeIntervalSince(package.date) >= Double(days)*86400 {
                do { try move(package.url);report.removed.append(package.url) } catch { report.failures += 1 }
            }
        } catch { report.failures += 1 }
        return report
    }
    static func samePackage(_ left:URL,_ right:URL)->Bool { left.resolvingSymlinksInPath().standardizedFileURL.path == right.resolvingSymlinksInPath().standardizedFileURL.path }
    func remove(_ selected:[URL],move:(URL)throws->Void = { try FileManager.default.trashItem(at:$0,resultingItemURL:nil) })->Report {
        var report = Report()
        do {
            let eligible = Set(try packages().map { $0.url.standardizedFileURL })
            for url in Set(selected.map(\.standardizedFileURL)) {
                guard eligible.contains(url) else { report.failures += 1; continue }
                do { try move(url); report.removed.append(url) } catch { report.failures += 1 }
            }
        } catch { report.failures += 1 }
        return report
    }
    static let clipboardType = NSPasteboard.PasteboardType("dev.pageglass.capture-path")
    static func clearClipboard(for removed:[URL],pasteboard:NSPasteboard = .general) {
        guard let path = pasteboard.string(forType:clipboardType),removed.contains(where:{ samePackage($0,URL(fileURLWithPath:path)) }) else { return }
        pasteboard.clearContents()
    }
}

extension BrowserWindow {
    var captureRoot:URL {
        if let index = CommandLine.arguments.firstIndex(of:"--smoke"),CommandLine.arguments.count > index+1 {
            return URL(fileURLWithPath:CommandLine.arguments[index+1]).appendingPathComponent("managed-captures")
        }
        return CaptureService.root
    }
    @discardableResult
    func cleanCaptures(all:Bool = false)->CaptureRetention.Report {
        let report = CaptureRetention(root:captureRoot).clean(days:store.state.settings.captureRetentionDays ?? 0,all:all)
        CaptureRetention.clearClipboard(for:report.removed)
        if let latest,report.removed.contains(where:{ CaptureRetention.samePackage($0,latest.directory) }) { self.latest = nil }
        if !report.removed.isEmpty { NotificationCenter.default.post(name:CaptureRetention.changed,object:captureRoot) }
        return report
    }
}
