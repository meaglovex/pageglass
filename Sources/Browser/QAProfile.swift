import Foundation

/// Explicit manual QA only: normal startup never reads or creates this profile.
struct QAProfile {
    let directory:URL
    let websiteDataID:UUID
    let width:Double?
    let appearance:String?

    static let current:QAProfile? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of:"--qa-profile") else { return nil }
        do {
            guard args.count > index+1,args[index+1].hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
            let directory = URL(fileURLWithPath:args[index+1],isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
            // Refuse the user profile and non-temporary directories, including symlink escapes.
            let temporary = URL(fileURLWithPath:"/tmp",isDirectory:true).resolvingSymlinksInPath().path
            guard directory.path.hasPrefix(temporary+"/") else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let identity = directory.appendingPathComponent("website-data-id.txt")
            let id:UUID
            if FileManager.default.fileExists(atPath:identity.path) {
                guard let saved = UUID(uuidString:try String(contentsOf:identity,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw CocoaError(.fileReadCorruptFile) }
                id = saved
            } else { id = UUID(); try id.uuidString.write(to:identity,atomically:true,encoding:.utf8) }
            func value(_ option:String)->String? { guard let i = args.firstIndex(of:option),args.count > i+1 else { return nil }; return args[i+1] }
            let width = value("--qa-width").flatMap(Double.init)
            let appearance = value("--qa-appearance")
            guard width == nil || [900.0,1280.0,1440.0].contains(width!),appearance == nil || ["Aqua","DarkAqua"].contains(appearance!) else { throw CocoaError(.fileReadCorruptFile) }
            return QAProfile(directory:directory,websiteDataID:id,width:width,appearance:appearance)
        } catch {
            fputs("QA profile refused: \(error.localizedDescription)\n",stderr); exit(2)
        }
    }()
}
