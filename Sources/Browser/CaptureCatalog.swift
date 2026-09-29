import AppKit
import ImageIO

struct CaptureRecord {
    let directory:URL
    let date:Date
    let originalTitle:String
    let source:String
    let mode:String
    let bytes:Int64
    let metadata:[String:Any]
    let problem:String?
    var edits = CaptureEdits()
    var editProblem:String?
    var title:String { edits.name.isEmpty ? originalTitle : edits.name }
    var scope:String { mode == "page" ? "当前已加载整页" : "元素可见区域" }
    var displaySource:String {
        guard let url = URL(string:source) else { return source }
        return url.isFileURL ? "本地文件 · \(url.lastPathComponent)" : source
    }
    var outcome:String { problem != nil ? "文件不可用" : metadata["outcome"] as? String == "partial" ? "部分捕获" : metadata["outcome"] as? String == "complete" ? "捕获完成" : "旧版捕获 · 请检查截图" }
    var warnings:[String] { (metadata["warnings"] as? [String] ?? []).prefix(40).map { String($0.prefix(2000)) } }
    func expiration(days:Int,now:Date = Date())->String {
        guard days > 0 else { return "永不过期" }
        let expiry = date.addingTimeInterval(Double(days)*86400)
        return expiry <= now ? "已到期，待清理" : "\(expiry.formatted(date:.abbreviated,time:.shortened)) 到期"
    }
}

enum CaptureCatalog {
    static func file(_ name:String,in directory:URL,limit:Int? = nil) throws->URL {
        guard ["capture.json","reference.html","screenshot.png","PROMPT.txt"].contains(name) else { throw CaptureService.Failure.message("未知捕获文件") }
        let parent = try directory.deletingLastPathComponent().resourceValues(forKeys:[.isSymbolicLinkKey])
        let container = try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        let file = directory.appendingPathComponent(name)
        let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        let limit = limit ?? (name == "screenshot.png" ? 128*1024*1024 : 32*1024*1024)
        guard parent.isSymbolicLink != true,container.isDirectory == true,container.isSymbolicLink != true,values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max) <= limit else { throw CaptureService.Failure.message("捕获文件不可用或超出读取限制，请重新捕获") }
        return file
    }
    static func metadata(in directory:URL) throws->[String:Any] {
        let data = try Data(contentsOf:file("capture.json",in:directory,limit:8*1024*1024))
        guard let metadata = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw CaptureService.Failure.message("捕获记录已损坏") }
        return metadata
    }
    static func size(of directory:URL)->Int64 {
        var total:Int64 = 0
        guard let container = try? directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),container.isDirectory == true,container.isSymbolicLink != true,
              let parent = try? directory.deletingLastPathComponent().resourceValues(forKeys:[.isSymbolicLinkKey]),parent.isSymbolicLink != true else { return 0 }
        guard let files = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey]) else { return 0 }
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
    static func record(_ directory:URL,date:Date? = nil)->CaptureRecord {
        let date = date ?? Date(timeIntervalSince1970:Double(directory.lastPathComponent.prefix(10)) ?? 0)
        do {
            let data = try metadata(in:directory)
            try validateSupportingFiles(in:directory)
            var record = CaptureRecord(directory:directory,date:date,originalTitle:String((data["title"] as? String ?? "未命名页面").prefix(512)),source:String((data["url"] as? String ?? "本地页面").prefix(2048)),mode:data["mode"] as? String ?? "element",bytes:size(of:directory),metadata:data,problem:nil)
            do { record.edits = try CaptureEdits.load(in:directory) } catch { record.editProblem = error.localizedDescription }
            return record
        } catch {
            return CaptureRecord(directory:directory,date:date,originalTitle:directory.lastPathComponent,source:"文件缺失或记录损坏",mode:"",bytes:size(of:directory),metadata:[:],problem:error.localizedDescription)
        }
    }
    static func scan(_ root:URL) throws->[CaptureRecord] {
        try CaptureRetention(root:root).packages().sorted { $0.date > $1.date }.map { record($0.url,date:$0.date) }
    }
    static func thumbnail(_ directory:URL,pixels:Int = 640)->NSImage? {
        guard let path = try? file("screenshot.png",in:directory),let source = CGImageSourceCreateWithURL(path as CFURL,nil),
              validDimensions(source),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        return NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
    }
    private static func validDimensions(_ source:CGImageSource)->Bool {
        guard let values = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],let width = values[kCGImagePropertyPixelWidth as String] as? Int,let height = values[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return width > 0 && height > 0 && width <= 32000 && height <= 32000 && width*height <= 32_000_000
    }
    static func validate(_ directory:URL) throws {
        _ = try metadata(in:directory)
        try validateSupportingFiles(in:directory)
    }
    private static func validateSupportingFiles(in directory:URL) throws {
        for name in ["reference.html","PROMPT.txt"] { _ = try file(name,in:directory) }
        let screenshot = try file("screenshot.png",in:directory)
        guard let source = CGImageSourceCreateWithURL(screenshot as CFURL,nil),validDimensions(source),CGImageSourceGetStatus(source) == .statusComplete else { throw CaptureService.Failure.message("截图已损坏或尺寸超出限制，请重新捕获") }
    }
    static func copyPrompt(_ directory:URL,pasteboard:NSPasteboard = CaptureClipboard.current) throws {
        try validate(directory)
        var prompt = try String(contentsOf:file("PROMPT.txt",in:directory,limit:2*1024*1024),encoding:.utf8)
        let edits = try CaptureEdits.load(in:directory)
        if !edits.name.isEmpty || !edits.notes.isEmpty || !edits.annotations.isEmpty {
            prompt += "\n\n用户整理与标注：\(directory.appendingPathComponent(CaptureEdits.filename).path)\n此文件的 name、notes 与 annotations 为用户另存的编辑内容；标注坐标相对于 screenshot.png 左上角，范围 0–1。请结合原截图读取。原网页证据未修改。\n"
            if !edits.notes.isEmpty { prompt += "\n用户备注与修改要求：\n"+edits.notes+"\n" }
        }
        pasteboard.clearContents(); pasteboard.setString(prompt,forType:.string)
        pasteboard.setString(directory.path,forType:CaptureRetention.clipboardType)
    }
    static func copyImage(_ directory:URL,pasteboard:NSPasteboard = CaptureClipboard.current) throws {
        try validate(directory)
        let path = try file("screenshot.png",in:directory)
        guard let source = CGImageSourceCreateWithURL(path as CFURL,nil),validDimensions(source),let raster = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CaptureService.Failure.message("截图无法读取或尺寸超出限制") }
        let image = NSImage(cgImage:raster,size:NSSize(width:raster.width,height:raster.height))
        pasteboard.clearContents(); pasteboard.writeObjects([image])
        pasteboard.setString(directory.path,forType:CaptureRetention.clipboardType)
    }
}
