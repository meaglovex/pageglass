import Foundation
import Darwin

/// User edits are separate from the immutable page evidence. Coordinates are relative to the PNG.
struct CaptureAnnotation:Codable,Equatable,Identifiable {
    enum Kind:String,Codable,CaseIterable { case rectangle,arrow,number,text }
    enum Color:String,Codable,CaseIterable { case red,blue,amber }
    var id = UUID()
    var kind:Kind
    var x:Double, y:Double, endX:Double, endY:Double
    var text = ""
    var color:Color = .red
    var bounds:CGRect { CGRect(x:min(x,endX),y:min(y,endY),width:abs(x-endX),height:abs(y-endY)) }
    func moved(dx:Double,dy:Double)->Self {
        var copy = self
        let dx = max(-min(x,endX),min(1-max(x,endX),dx)), dy = max(-min(y,endY),min(1-max(y,endY),dy))
        copy.x += dx; copy.endX += dx; copy.y += dy; copy.endY += dy
        return copy
    }
}

struct CaptureEdits:Codable,Equatable {
    var version = 1
    var revision:UUID?
    var name = ""
    var notes = ""
    var annotations:[CaptureAnnotation] = []
    func validate() throws {
        guard version == 1 else { throw Failure.message("此捕获的编辑数据来自其他版本，当前版本不会覆盖它") }
        guard name.count <= 200,notes.count <= 8000,annotations.count <= 200 else { throw Failure.message("名称最多 200 字，备注最多 8000 字，标注最多 200 个") }
        guard Set(annotations.map(\.id)).count == annotations.count,annotations.allSatisfy({ mark in
            [mark.x,mark.y,mark.endX,mark.endY].allSatisfy { $0.isFinite && (0...1).contains($0) } && mark.text.count <= 500
        }) else { throw Failure.message("标注位置或文字无效；每条文字最多 500 字") }
    }
    enum Failure:LocalizedError {
        case message(String)
        var errorDescription:String? { if case .message(let value) = self { return value }; return nil }
    }
    static let filename = "pageglass.json"
    static let changed = Notification.Name("PageglassCaptureEditsChanged")
    private static let limit = 512*1024

    private static func withDirectory<T>(_ directory:URL,_ operation:(Int32)throws->T) throws->T {
        let parent = try directory.deletingLastPathComponent().resourceValues(forKeys:[.isSymbolicLinkKey])
        guard parent.isSymbolicLink != true else { throw Failure.message("捕获目录不可用") }
        let descriptor = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.message("捕获目录不存在、不可读或为符号链接") }
        defer { Darwin.close(descriptor) }
        return try operation(descriptor)
    }
    private static func load(at directory:Int32) throws->Self {
        let descriptor = openat(directory,filename,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Self() }
            throw Failure.message("编辑数据不可读或为符号链接，未覆盖原数据")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG,info.st_size >= 0,info.st_size <= limit else { throw Failure.message("编辑文件类型或大小无效") }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        let bytes = try handle.read(upToCount:limit+1) ?? Data()
        guard bytes.count == info.st_size,bytes.count <= limit else { throw Failure.message("编辑数据读取不完整") }
        let edits:Self
        do { edits = try JSONDecoder().decode(Self.self,from:bytes) }
        catch { throw Failure.message("编辑数据已损坏，原捕获仍可查看；未覆盖编辑文件") }
        try edits.validate(); return edits
    }
    static func load(in directory:URL) throws->Self { try withDirectory(directory) { try load(at:$0) } }

    /// Compare-and-save stops two open editors from silently overwriting each other.
    @discardableResult
    func save(in directory:URL,expectedRevision:UUID?) throws->Self {
        try validate()
        try CaptureCatalog.validate(directory)
        return try Self.withDirectory(directory) { descriptor in
            guard flock(descriptor,LOCK_EX) == 0 else { throw Failure.message("无法锁定捕获目录，请重试") }
            defer { flock(descriptor,LOCK_UN) }
            let current = try Self.load(at:descriptor)
            guard current.revision == expectedRevision else { throw Failure.message("此捕获已在其他窗口更新。请保留当前内容，重新打开后再修改") }
            var saved = self; saved.revision = UUID()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            let data = try encoder.encode(saved)
            guard data.count <= Self.limit else { throw Failure.message("编辑数据过大，请减少标注文字") }
            let temporary = ".pageglass-\(UUID().uuidString).tmp"
            let file = openat(descriptor,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
            guard file >= 0 else { throw Failure.message("捕获目录无法写入，修改仍保留在窗口中") }
            defer { Darwin.close(file); unlinkat(descriptor,temporary,0) }
            try FileHandle(fileDescriptor:file,closeOnDealloc:false).write(contentsOf:data)
            guard fsync(file) == 0,renameat(descriptor,temporary,descriptor,Self.filename) == 0 else { throw Failure.message("保存未完成，修改仍保留在窗口中，请重试") }
            return saved
        }
    }
}

enum CaptureRecordFilter {
    static func matches(_ record:CaptureRecord,query:String,mode:String? = nil,since:Date? = nil)->Bool {
        if let mode,record.mode != mode { return false }
        if let since,record.date < since { return false }
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return query.isEmpty || [record.title,record.originalTitle,record.source,record.edits.notes].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
