import Foundation
import WebKit

@MainActor
enum CaptureAssets {
    static let script = (try? String(contentsOf:Resources.bundle.url(forResource:"capture-assets",withExtension:"js",subdirectory:"Resources")!,encoding:.utf8)) ?? ""
    struct Result { var html:String; var manifest:[[String:Any]]; var warnings:[String]; var paths:[String:String] }

    static func bundle(_ view:WKWebView,html:String,references:[[String:String]],folder:URL) async throws -> Result {
        try Task.checkCancellation()
        guard !references.isEmpty else { return Result(html:html,manifest:[],warnings:[],paths:[:]) }
        let urls = Array(Set(references.compactMap { $0["url"] })).sorted()
        var items: [[String:Any]]
        do {
            let raw:Any? = try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(script,arguments:["urls":urls],in:nil,in:CaptureService.world) { result in continuation.resume(with:result) }
            }
            items = raw as? [[String:Any]] ?? []
        } catch { try Task.checkCancellation(); items = urls.map { ["url":$0,"status":"page-fetch-failed"] } }
        try Task.checkCancellation()
        let directory = folder.appendingPathComponent("assets",isDirectory:true)
        var replacements: [String:String] = [:], manifest: [[String:Any]] = [], total = 0
        for (index,var item) in items.enumerated() {
            try Task.checkCancellation()
            guard let url = item["url"] as? String else { continue }
            let encoded = item.removeValue(forKey:"base64") as? String
            if item["status"] as? String == "bundled", let encoded,encoded.count <= 2_800_000,let bytes = Data(base64Encoded:encoded), !bytes.isEmpty,bytes.count <= 2*1024*1024,total+bytes.count <= 20*1024*1024,let ext = fileExtension(bytes) {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let name = "assets/resource-\(index).\(ext)"
                try bytes.write(to:folder.appendingPathComponent(name),options:.atomic)
                replacements[url] = name; total += bytes.count; item["file"] = name; item["bytes"] = bytes.count
            } else if item["status"] as? String == "bundled" { item["status"] = "invalid-data-or-limit" }
            manifest.append(item)
        }
        let output = resolve(html,references:references,paths:replacements)
        let missing = urls.filter { replacements[$0] == nil && !$0.hasPrefix("data:") }.count
        return Result(html:output,manifest:manifest,warnings:missing > 0 ? ["\(missing) 个图片或字体资源未能离线保存（跨域限制、超时、格式或预算）；保留原地址，详见 assetManifest。"] : [],paths:replacements)
    }
    static func resolve(_ html:String,references:[[String:String]],paths:[String:String],prefix:String = "")->String {
        var output = html
        for reference in references {
            guard let token = reference["token"],let url = reference["url"] else { continue }
            let replacement = paths[url].map { prefix+$0 } ?? url
            output = output.replacingOccurrences(of:token,with:reference["context"] == "html" ? escapeHTML(replacement) : escapeCSS(replacement))
        }
        return output
    }
    static func escapeHTML(_ string:String)->String {
        string.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"'",with:"&#39;")
    }
    static func escapeCSS(_ string:String)->String {
        string.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"%0A").replacingOccurrences(of:"\r",with:"%0D").replacingOccurrences(of:"<",with:"%3C")
    }
    // The server's MIME type alone cannot turn an HTML error response into a saved image/font.
    static func fileExtension(_ data:Data)->String? {
        let b = [UInt8](data.prefix(16)), ascii = String(decoding:data.prefix(16),as:UTF8.self)
        if b.starts(with:[137,80,78,71,13,10,26,10]) { return "png" }
        if b.starts(with:[255,216,255]) { return "jpg" }
        if ascii.hasPrefix("GIF87a") || ascii.hasPrefix("GIF89a") { return "gif" }
        if ascii.hasPrefix("RIFF"),b.count >= 12,String(decoding:b[8..<12],as:UTF8.self) == "WEBP" { return "webp" }
        if b.count >= 12,String(decoding:b[4..<8],as:UTF8.self) == "ftyp",["avif","avis"].contains(String(decoding:b[8..<12],as:UTF8.self)) { return "avif" }
        if ascii.hasPrefix("BM") { return "bmp" }
        if b.starts(with:[0,0,1,0]) { return "ico" }
        if ascii.hasPrefix("wOFF") { return "woff" }; if ascii.hasPrefix("wOF2") { return "woff2" }
        if ascii.hasPrefix("OTTO") { return "otf" }; if b.starts(with:[0,1,0,0]) || ascii.hasPrefix("true") { return "ttf" }
        return nil
    }
}
