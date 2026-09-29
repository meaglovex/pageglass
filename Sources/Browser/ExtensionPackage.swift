import Foundation
import CryptoKit
import Darwin

struct ExtensionPackage {
    struct Failure:LocalizedError { let message:String; var errorDescription:String? { message } }
    static let fileLimit = 8 * 1024 * 1024, totalLimit = 64 * 1024 * 1024, countLimit = 2000
    static let supportedPermissions:Set<String> = ["storage","tabs","activeTab","alarms"]
    let directory:URL
    let name:String, version:String, sourceName:String, digest:String
    let permissions:[String], hosts:[String]

    static func validVersion(_ value:String)->Bool {
        let parts = value.split(separator:".",omittingEmptySubsequences:false)
        return (1...4).contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 5 && (part.count == 1 || part.first != "0") && part.utf8.allSatisfy { (48...57).contains($0) } && (Int(part) ?? 65536) <= 65535
        } && parts.contains { (Int($0) ?? 0) > 0 }
    }

    static func path(_ name:String) throws->String {
        let parts = name.split(separator:"/",omittingEmptySubsequences:false)
        guard !name.isEmpty,!name.contains("\\"),!name.contains(":"),!name.contains("%"),
              !name.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),name.utf8.count <= 1024 else {
            throw Failure(message:"扩展包含无效或越界路径：\(String(name.prefix(120)))")
        }
        return name
    }
    /// O_NOFOLLOW on every component prevents a changing source directory from redirecting reads.
    static func read(_ relative:String,from root:URL,limit:Int = fileLimit) throws->Data {
        let relative = try path(relative)
        var descriptor = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure(message:"扩展目录不可读，或目录是符号链接") }
        defer { Darwin.close(descriptor) }
        let parts = relative.split(separator:"/").map(String.init)
        for (index,part) in parts.enumerated() {
            let next = openat(descriptor,part,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index == parts.count-1 ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw Failure(message:"扩展文件不可读或包含符号链接：\(relative)") }
            Darwin.close(descriptor); descriptor = next
        }
        var info = stat()
        guard fstat(descriptor,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG,info.st_size >= 0,info.st_size <= limit else {
            throw Failure(message:"扩展文件类型或大小不受支持：\(relative)")
        }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        var data = Data()
        while data.count <= limit {
            guard let block = try handle.read(upToCount:min(65536,limit+1-data.count)),!block.isEmpty else { break }
            data.append(block)
        }
        guard data.count <= limit,data.count == info.st_size else { throw Failure(message:"读取时扩展文件发生变化或超出大小限制：\(relative)") }
        return data
    }
    static func prepare(source:URL,in stagingRoot:URL) throws->ExtensionPackage {
        let fm = FileManager.default
        guard try source.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure(message:"请选择真实扩展目录或 ZIP，不使用符号链接") }
        // Foundation normalizes /private/var differently from enumeration; use the filesystem's path.
        guard let resolved = realpath(source.path,nil) else { throw Failure(message:"扩展来源不可读") }
        let source = URL(fileURLWithPath:String(cString:resolved)); free(resolved)
        try fm.createDirectory(at:stagingRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let destination = stagingRoot.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            if try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory == true {
                guard try source.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure(message:"请选择真实扩展目录，不使用符号链接") }
                _ = try read("manifest.json",from:source,limit:1024*1024)
                let keys:[URLResourceKey] = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]
                var traversalError:Error?
                guard let enumerator = fm.enumerator(at:source,includingPropertiesForKeys:keys,options:[],errorHandler:{ _,error in traversalError = error; return false }) else { throw Failure(message:"无法读取扩展目录") }
                var count = 0,total = 0,seen = Set<String>()
                for case let url as URL in enumerator {
                    guard url.path.hasPrefix(source.path+"/") else { throw Failure(message:"扩展目录路径发生变化") }
                    let name = String(url.path.dropFirst(source.path.count+1))
                    if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
                    if url.lastPathComponent == ".DS_Store" { continue }
                    _ = try path(name)
                    let values = try url.resourceValues(forKeys:Set(keys))
                    guard values.isSymbolicLink != true else { throw Failure(message:"扩展中不允许符号链接：\(name)") }
                    count += 1; guard count <= countLimit else { throw Failure(message:"扩展超过 2000 个文件或目录，请选择构建后的扩展目录") }
                    if values.isDirectory == true { continue }
                    guard values.isRegularFile == true else { throw Failure(message:"扩展中不允许特殊文件：\(name)") }
                    guard seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw Failure(message:"扩展中存在重名文件") }
                    let data = try read(name,from:source); total += data.count
                    guard total <= totalLimit else { throw Failure(message:"扩展解包后超过 64 MiB") }
                    let target = destination.appendingPathComponent(name)
                    try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try data.write(to:target,options:.withoutOverwriting)
                }
                if let traversalError { throw traversalError }
            } else {
                guard source.pathExtension.lowercased() == "zip" else { throw Failure(message:"请选择含 manifest.json 的目录或 ZIP 文件") }
                let archive = try read(source.lastPathComponent,from:source.deletingLastPathComponent(),limit:32*1024*1024)
                try ExtensionZIP.extract(archive,to:destination)
            }
            return try inspect(destination,sourceName:source.lastPathComponent)
        } catch { try? fm.removeItem(at:destination); throw error }
    }
    static func inspect(_ directory:URL,sourceName:String) throws->ExtensionPackage {
        let data = try read("manifest.json",from:directory,limit:1024*1024)
        guard let manifest = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              manifest["manifest_version"] as? Int == 3,
              let name = manifest["name"] as? String,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let version = manifest["version"] as? String,validVersion(version) else { throw Failure(message:"需要有效的 Manifest V3 扩展：版本须为 1–4 段数字，每段 0–65535，不含前导零，且不能全为零") }
        func strings(_ key:String,_ object:[String:Any]) throws->[String] {
            guard let value = object[key] else { return [] }
            guard let list = value as? [String] else { throw Failure(message:"manifest 的 \(key) 格式不正确") }; return list
        }
        let permissions = try strings("permissions",manifest), optional = try strings("optional_permissions",manifest)
        let unsupported = Set(permissions+optional).subtracting(supportedPermissions)
        guard unsupported.isEmpty else { throw Failure(message:"此版本暂不支持扩展权限：\(unsupported.sorted().joined(separator:", "))") }
        for key in ["declarative_net_request","devtools_page","chrome_url_overrides","chrome_settings_overrides","side_panel","sandbox","externally_connectable"] where manifest[key] != nil { throw Failure(message:"此版本暂不支持扩展能力：\(key)") }
        var hosts = try strings("host_permissions",manifest)+strings("optional_host_permissions",manifest)
        var resources:[String] = []
        if let scripts = manifest["content_scripts"] {
            guard let scripts = scripts as? [[String:Any]] else { throw Failure(message:"content_scripts 格式不正确") }
            for script in scripts {
                guard (script["world"] as? String ?? "ISOLATED") == "ISOLATED",script["match_about_blank"] as? Bool != true,script["match_origin_as_fallback"] as? Bool != true else { throw Failure(message:"此版本不支持页面主世界或继承来源注入") }
                hosts += try strings("matches",script)
                resources += try strings("js",script)+strings("css",script)
            }
        }
        for host in hosts {
            guard host == "<all_urls>" || host.hasPrefix("https://") || host.hasPrefix("http://") || host.hasPrefix("*://") else { throw Failure(message:"扩展请求不受支持的网站范围：\(host)") }
        }
        if let background = manifest["background"] as? [String:Any] {
            if let worker = background["service_worker"] as? String { resources.append(worker) }
            guard background["scripts"] == nil,background["page"] == nil else { throw Failure(message:"此版本仅支持 MV3 service worker 后台") }
        }
        if let action = manifest["action"] as? [String:Any],let popup = action["default_popup"] as? String,!popup.isEmpty { resources.append(popup) }
        if let page = manifest["options_page"] as? String { resources.append(page) }
        if let options = manifest["options_ui"] as? [String:Any],let page = options["page"] as? String { resources.append(page) }
        for resource in resources { _ = try read(resource,from:directory) }
        let entries = try FileManager.default.subpathsOfDirectory(atPath:directory.path).sorted()
        guard entries.count <= countLimit else { throw Failure(message:"扩展文件数量超限") }
        var hasher = SHA256(); var total = 0
        for relative in entries {
            let url = directory.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure(message:"扩展中不允许符号链接：\(relative)") }
            if values.isDirectory == true { continue }
            let content = try read(relative,from:directory); total += content.count
            guard total <= totalLimit else { throw Failure(message:"扩展总大小超限") }
            hasher.update(data:Data(relative.utf8)); hasher.update(data:Data([0])); hasher.update(data:content)
        }
        return ExtensionPackage(directory:directory,name:String(name.prefix(200)),version:String(version.prefix(64)),sourceName:sourceName,digest:hasher.finalize().map{String(format:"%02x",$0)}.joined(),permissions:permissions.sorted(),hosts:Array(Set(hosts)).sorted())
    }
}
