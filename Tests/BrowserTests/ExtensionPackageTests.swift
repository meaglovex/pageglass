import XCTest
import zlib
@testable import Browser

final class ExtensionPackageTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pageglass-extension-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    private func manifest(_ changes:[String:Any] = [:]) throws->Data {
        var value:[String:Any] = ["manifest_version":3,"name":"Owned fixture","version":"1.0","description":"Package validation fixture","permissions":["storage"]]
        changes.forEach { value[$0] = $1 }
        return try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
    }
    private func source(_ changes:[String:Any] = [:]) throws->URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        try manifest(changes).write(to:directory.appendingPathComponent("manifest.json")); return directory
    }
    private func prepare(_ source:URL) throws->ExtensionPackage { try ExtensionPackage.prepare(source:source,in:root.appendingPathComponent("stage")) }

    func testManagedCopyDoesNotFollowChangesToOriginal() throws {
        let folder = try source(["content_scripts":[["matches":["https://example.test/*"],"js":["content.js"]]]])
        try Data("original".utf8).write(to:folder.appendingPathComponent("content.js"))
        let package = try prepare(folder)
        try Data("changed".utf8).write(to:folder.appendingPathComponent("content.js"))
        XCTAssertEqual(try ExtensionPackage.read("content.js",from:package.directory),Data("original".utf8))
        XCTAssertEqual(try ExtensionPackage.inspect(package.directory,sourceName:"test").digest,package.digest)
        try Data("modified managed copy".utf8).write(to:package.directory.appendingPathComponent("content.js"))
        XCTAssertNotEqual(try ExtensionPackage.inspect(package.directory,sourceName:"test").digest,package.digest)
    }
    func testRejectsUnsupportedCapabilitiesAndMainWorld() throws {
        for change:[String:Any] in [
            ["manifest_version":2],["permissions":["scripting"]],["optional_permissions":["nativeMessaging"]],
            ["declarative_net_request":[:]], ["permissions":["storage",42]],
            ["content_scripts":[["world":"MAIN","matches":["https://example.test/*"],"js":[]]]],
            ["content_scripts":[["match_about_blank":true,"matches":["https://example.test/*"]]]],
            ["host_permissions":["file:///*"]], ["options_page":"../outside.html"],
            ["background":["service_worker":"missing.js"]]
        ] { XCTAssertThrowsError(try prepare(source(change)),"\(change)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("stage").path),[])
    }
    func testRejectsFileDirectoryAndAncestorSymlinks() throws {
        let folder = try source(),outside = try source(),fm = FileManager.default
        let link = folder.appendingPathComponent("linked")
        try fm.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertThrowsError(try prepare(folder))
        XCTAssertThrowsError(try ExtensionPackage.inspect(folder,sourceName:"test"))
        XCTAssertThrowsError(try ExtensionPackage.read("linked/manifest.json",from:folder))
        try fm.removeItem(at:link)
        try fm.createSymbolicLink(at:link,withDestinationURL:outside.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try prepare(folder))
        XCTAssertThrowsError(try ExtensionPackage.read("linked",from:folder))
        XCTAssertEqual(try ExtensionPackage.read("manifest.json",from:outside),try manifest())
    }
    func testZIPStoredDeflatedAndEmptyDirectories() throws {
        for deflated in [false,true] {
            let archive = root.appendingPathComponent("valid-\(deflated).zip")
            let entries = [Entry("manifest.json",try manifest()),Entry("assets/",Data()),Entry("assets/value.txt",Data("hello ✓".utf8))]
            try zip(entries,deflated:deflated).write(to:archive)
            let package = try prepare(archive)
            XCTAssertEqual(try ExtensionPackage.read("assets/value.txt",from:package.directory),Data("hello ✓".utf8))
        }
    }
    func testManifestVersionFollowsNumericExtensionFormat() throws {
        for version in ["1","0.1.0.0","3.1.2.4567","65535.0"] { XCTAssertTrue(ExtensionPackage.validVersion(version)) }
        for version in ["","0","0.0.0.0","1.01","01.2","1..2","1.2.3.4.5","65536","1.0-beta"," 1","１"] {
            XCTAssertFalse(ExtensionPackage.validVersion(version)); XCTAssertThrowsError(try prepare(source(["version":version])))
        }
    }
    func testZIPRejectsTraversalSymlinksDuplicatesAndFileDirectoryConflict() throws {
        var cases:[[Entry]] = ["../escape","/absolute","a/../../escape","a\\escape","a//b","a/%2e%2e/b"].map { [Entry($0,Data("unsafe".utf8))] }
        cases += [[Entry("link",Data("../outside".utf8),mode:0xa000)], [Entry("A",Data()),Entry("a",Data())], [Entry("folder",Data()),Entry("folder/value",Data())]]
        for (index,entries) in cases.enumerated() {
            let archive = root.appendingPathComponent("invalid-\(index).zip")
            try zip([Entry("manifest.json",try manifest())]+entries).write(to:archive)
            XCTAssertThrowsError(try prepare(archive))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("escape").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("stage").path),[])
    }
    func testZIPRejectsCRCTruncationAndInflatedSizeMismatch() throws {
        let archive = root.appendingPathComponent("invalid.zip"),valid = try zip([Entry("manifest.json",try manifest())])
        var corrupt = valid; corrupt[30+"manifest.json".utf8.count] ^= 1
        var nameMismatch = valid; nameMismatch[30] = 120
        let bomb = try zip([Entry("manifest.json",try manifest()),Entry("large",Data(repeating:65,count:1024*1024),declaredSize:1)],deflated:true)
        let oversized = try zip([Entry("manifest.json",try manifest()),Entry("oversized",Data(),declaredSize:ExtensionPackage.fileLimit+1)])
        for data in [corrupt,nameMismatch,Data(valid.dropLast()),bomb,oversized] {
            try data.write(to:archive); XCTAssertThrowsError(try prepare(archive))
        }
    }
    func testZIPRejectsOverlappingLocalRecords() throws {
        let nested = Entry("nested.bin",Data("x".utf8))
        let nestedLocal = try zip([nested]).prefix(30+nested.name.utf8.count+nested.data.count)
        let carrier = Entry("carrier.bin",Data(nestedLocal))
        var data = try zip([carrier,nested,Entry("manifest.json",try manifest())])
        let centralStart = (0..<4).reduce(0) { $0 | Int(data[data.count-6+$1]) << (8*$1) }
        let secondOffsetField = centralStart+46+carrier.name.utf8.count+42
        let nestedOffset = 30+carrier.name.utf8.count
        for byte in 0..<4 { data[secondOffsetField+byte] = UInt8(truncatingIfNeeded:nestedOffset >> (8*byte)) }
        let archive = root.appendingPathComponent("overlap.zip"); try data.write(to:archive)
        XCTAssertThrowsError(try prepare(archive)) { error in XCTAssertTrue(error.localizedDescription.contains("重叠数据")) }
    }
    func testRepositoryPersistsIdentityAndFailedSavePreservesState() throws {
        let package = try prepare(source()),repository = ExtensionRepository(directory:root.appendingPathComponent("profile"))
        var record = repository.adopt(package,replacing:nil); record.sites["https://example.test/*"] = false
        try repository.replace(record)
        let reopened = ExtensionRepository(directory:root.appendingPathComponent("profile"))
        XCTAssertEqual(reopened.state.controllerID,repository.state.controllerID)
        let updated = reopened.adopt(package,replacing:reopened.state.items.first)
        XCTAssertEqual(updated.id,record.id); XCTAssertEqual(updated.sites,record.sites); XCTAssertNotEqual(updated.package,record.package)
        let file = repository.root.appendingPathComponent("extensions.json")
        try Data("corrupt-original".utf8).write(to:file)
        let broken = ExtensionRepository(directory:root.appendingPathComponent("profile"))
        XCTAssertNotNil(broken.readError); XCTAssertThrowsError(try broken.save([]))
        XCTAssertEqual(try Data(contentsOf:file),Data("corrupt-original".utf8))
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:root.appendingPathComponent("missing"))
        let dangling = ExtensionRepository(directory:root.appendingPathComponent("profile"))
        XCTAssertNotNil(dangling.readError); XCTAssertThrowsError(try dangling.save([]))
    }

    private struct Entry {
        let name:String,data:Data,mode:Int,declaredSize:Int?
        init(_ name:String,_ data:Data,mode:Int = 0,declaredSize:Int? = nil) { self.name = name; self.data = data; self.mode = mode; self.declaredSize = declaredSize }
    }
    /// Generates owned archives in memory, including adversarial central/local headers.
    private func zip(_ entries:[Entry],deflated:Bool = false) throws->Data {
        func append(_ value:Int,_ size:Int,to data:inout Data) { for byte in 0..<size { data.append(UInt8(truncatingIfNeeded:value >> (8*byte))) } }
        var local = Data(),central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8),offset = local.count,size = entry.declaredSize ?? entry.data.count
            let crc = entry.data.withUnsafeBytes { crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt(entry.data.count)) }
            let payload:Data
            if deflated {
                var stream = z_stream(),output = [UInt8](repeating:0,count:entry.data.count+1024)
                XCTAssertEqual(deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)),Z_OK)
                defer { deflateEnd(&stream) }
                let status = entry.data.withUnsafeBytes { input in output.withUnsafeMutableBytes { buffer in
                    stream.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:UInt8.self).baseAddress); stream.avail_in = uInt(input.count)
                    stream.next_out = buffer.bindMemory(to:UInt8.self).baseAddress; stream.avail_out = uInt(buffer.count)
                    return deflate(&stream,Z_FINISH)
                } }
                XCTAssertEqual(status,Z_STREAM_END); payload = Data(output.prefix(Int(stream.total_out)))
            } else { payload = entry.data }
            for (value,width) in [(0x04034b50,4),(20,2),(0x800,2),(deflated ? 8 : 0,2),(0,2),(0,2),(Int(crc),4),(payload.count,4),(size,4),(name.count,2),(0,2)] { append(value,width,to:&local) }
            local.append(name); local.append(payload)
            for (value,width) in [(0x02014b50,4),(0x0314,2),(20,2),(0x800,2),(deflated ? 8 : 0,2),(0,2),(0,2),(Int(crc),4),(payload.count,4),(size,4),(name.count,2),(0,2),(0,2),(0,2),(0,2),(entry.mode << 16,4),(offset,4)] { append(value,width,to:&central) }
            central.append(name)
        }
        var result = local; result.append(central)
        for (value,width) in [(0x06054b50,4),(0,2),(0,2),(entries.count,2),(entries.count,2),(central.count,4),(local.count,4),(0,2)] { append(value,width,to:&result) }
        return result
    }
}
