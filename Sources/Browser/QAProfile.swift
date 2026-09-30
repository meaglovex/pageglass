import Foundation

/// Manual QA profiles are explicit and temporary. A marked QA app must never fall back to user data.
struct QAProfile {
    static let requiredKey = "PageglassRequiresIsolatedProfile"
    let directory:URL
    let websiteDataID:UUID
    let width:Double?
    let appearance:String?

    static let current:QAProfile? = {
        do { return try load(arguments:CommandLine.arguments,requiresIsolation:Bundle.main.object(forInfoDictionaryKey:requiredKey) as? Bool == true) }
        catch { fputs("QA profile refused: \(error.localizedDescription)\n",stderr); exit(2) }
    }()

    static func load(arguments:[String],requiresIsolation:Bool) throws->QAProfile? {
        func value(_ option:String) throws->String? {
            let indexes = arguments.indices.filter { arguments[$0] == option }
            guard indexes.count <= 1 else { throw CocoaError(.fileReadInvalidFileName) }
            guard let index = indexes.first else { return nil }
            guard arguments.count > index+1,!arguments[index+1].hasPrefix("--") else { throw CocoaError(.fileReadInvalidFileName) }
            return arguments[index+1]
        }
        let path = try value("--qa-profile"),rawWidth = try value("--qa-width"),appearance = try value("--qa-appearance")
        guard let path else {
            guard !requiresIsolation,rawWidth == nil,appearance == nil else { throw CocoaError(.fileReadNoPermission) }
            return nil
        }
        guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let width = rawWidth.flatMap(Double.init)
        guard rawWidth == nil || (width != nil && [900.0,1280.0,1440.0].contains(width!)),
              appearance == nil || ["Aqua","DarkAqua"].contains(appearance!) else { throw CocoaError(.fileReadCorruptFile) }
        let directory = URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath:"/tmp",isDirectory:true).resolvingSymlinksInPath().path
        guard directory.path.hasPrefix(temporary+"/") else { throw CocoaError(.fileWriteNoPermission) }
        let fm = FileManager.default
        let identity = directory.appendingPathComponent("website-data-id.txt")
        if fm.fileExists(atPath:directory.path) {
            guard try directory.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadInvalidFileName) }
        }
        // Validate before creating any files. Never follow an identity file supplied as a symlink.
        let id:UUID
        if let values = try? identity.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) {
            guard values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? 4097) <= 4096,
                  let saved = UUID(uuidString:try String(contentsOf:identity,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw CocoaError(.fileReadCorruptFile) }
            id = saved
        } else {
            // resourceValues may fail for a dangling symlink; do not overwrite it either.
            guard (try? fm.destinationOfSymbolicLink(atPath:identity.path)) == nil else { throw CocoaError(.fileReadNoPermission) }
            id = UUID()
            try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try id.uuidString.write(to:identity,atomically:true,encoding:.utf8)
        }
        return QAProfile(directory:directory,websiteDataID:id,width:width,appearance:appearance)
    }
}
