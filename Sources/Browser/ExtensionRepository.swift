import Foundation

struct InstalledExtension:Codable,Identifiable {
    var id:UUID
    var package:UUID?
    var name:String,version:String,sourceName:String,digest:String
    var permissions:[String],hosts:[String]
    var enabled:Bool
    var sites:[String:Bool] = [:]
    var toolbarVisible:Bool? = nil
}

/// Separate registry: browser bookmarks/history/session formats do not change.
final class ExtensionRepository {
    struct State:Codable { var controllerID = UUID(); var items:[InstalledExtension] = [] }
    let root:URL
    private(set) var state = State()
    private(set) var readError:String?
    init(directory:URL) {
        root = directory.appendingPathComponent("Extensions",isDirectory:true)
        let file = root.appendingPathComponent("extensions.json")
        if (try? FileManager.default.attributesOfItem(atPath:file.path)) != nil {
            do {
                state = try JSONDecoder().decode(State.self,from:ExtensionPackage.read("extensions.json",from:root,limit:1024*1024))
                guard Set(state.items.map(\.id)).count == state.items.count else { throw ExtensionPackage.Failure(message:"扩展登记包含重复标识") }
            } catch { readError = "扩展登记读取失败，原文件已保留：\(error.localizedDescription)" }
        }
    }
    var staging:URL { root.appendingPathComponent("Staging",isDirectory:true) }
    func directory(for record:InstalledExtension)->URL? {
        record.package.map { root.appendingPathComponent("Packages",isDirectory:true).appendingPathComponent(record.id.uuidString,isDirectory:true).appendingPathComponent($0.uuidString,isDirectory:true) }
    }
    func save(_ items:[InstalledExtension]) throws {
        guard readError == nil else { throw ExtensionPackage.Failure(message:readError!) }
        var next = state; next.items = items
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard try root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw ExtensionPackage.Failure(message:"扩展存储目录不可使用符号链接") }
        try JSONEncoder().encode(next).write(to:root.appendingPathComponent("extensions.json"),options:.atomic)
        state = next
    }
    func replace(_ record:InstalledExtension) throws {
        var items = state.items
        if let index = items.firstIndex(where:{$0.id == record.id}) { items[index] = record } else { items.append(record) }
        try save(items)
    }
    func adopt(_ prepared:ExtensionPackage,replacing old:InstalledExtension?)->InstalledExtension {
        InstalledExtension(id:old?.id ?? UUID(),package:UUID(),name:prepared.name,version:prepared.version,sourceName:prepared.sourceName,digest:prepared.digest,permissions:prepared.permissions,hosts:prepared.hosts,enabled:true,sites:old?.sites ?? [:],toolbarVisible:old?.toolbarVisible)
    }
}
