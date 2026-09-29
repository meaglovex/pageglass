import XCTest
import AppKit
@testable import Browser

final class CaptureCatalogTests:XCTestCase {
    private func png() throws->Data {
        let raster = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        return try XCTUnwrap(raster.representation(using:.png,properties:[:]))
    }
    func testCorruptScreenshotCannotReplaceClipboardWithBrokenHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for name in ["capture.json","reference.html","PROMPT.txt","screenshot.png"] { try Data("{}".utf8).write(to:root.appendingPathComponent(name)) }
        let clipboard = NSPasteboard.general
        clipboard.clearContents(); clipboard.setString("keep valid clipboard",forType:.string)
        XCTAssertNotNil(CaptureCatalog.record(root).problem)
        XCTAssertThrowsError(try CaptureCatalog.copyPrompt(root))
        XCTAssertEqual(clipboard.string(forType:.string),"keep valid clipboard")
    }
    func testCatalogLoadsLegacyPartialAndCorruptRecordsWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        func create(_ name:String,_ metadata:String) throws->URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data(metadata.utf8).write(to:folder.appendingPathComponent("capture.json"))
            for file in ["reference.html","PROMPT.txt"] { try Data("fixture".utf8).write(to:folder.appendingPathComponent(file)) }
            try png().write(to:folder.appendingPathComponent("screenshot.png"))
            return folder
        }
        let legacy = try create("1700000000-AAAAAAAA",#"{"version":2,"mode":"element","title":"Old button","url":"https://example.com"}"#)
        _ = try create("1700000001-BBBBBBBB",#"{"version":3,"outcome":"partial","qualityIssues":["missing-assets"],"mode":"page","title":"Partial"}"#)
        _ = try create("1700000002-CCCCCCCC","broken JSON")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("1700000003-DDDDDDDD"),withDestinationURL:legacy)
        let records = try CaptureCatalog.scan(root)
        XCTAssertEqual(records.count,3); XCTAssertNotNil(records[0].problem)
        XCTAssertEqual(records[1].outcome,"部分捕获"); XCTAssertEqual(records[2].title,"Old button")
        XCTAssertTrue(records[2].outcome.contains("旧版"))
        let reference = legacy.appendingPathComponent("reference.html")
        try FileManager.default.removeItem(at:reference)
        try FileManager.default.createSymbolicLink(at:reference,withDestinationURL:legacy.appendingPathComponent("PROMPT.txt"))
        XCTAssertThrowsError(try CaptureCatalog.validate(legacy))
    }
    func testSelectedRemovalCannotDeleteUnknownOrUnselectedPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let selected = root.appendingPathComponent("1700000000-AAAAAAAA",isDirectory:true), other = root.appendingPathComponent("1700000000-BBBBBBBB",isDirectory:true), unknown = root.appendingPathComponent("personal-files",isDirectory:true)
        for folder in [selected,other,unknown] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data("{}".utf8).write(to:folder.appendingPathComponent("capture.json"))
        }
        var moved:[URL] = []
        let report = CaptureRetention(root:root).remove([selected,unknown]) { moved.append($0) }
        XCTAssertEqual(moved,[selected]); XCTAssertEqual(report.removed,[selected]); XCTAssertEqual(report.failures,1)
        let failure = CaptureRetention(root:root).remove([other]) { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(failure.failures,1); XCTAssertTrue(failure.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:other.path))
    }
    func testExpirationAndTwoHundredLegacyRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let image = try png()
        for index in 0..<200 {
            let folder = root.appendingPathComponent("1700000000-"+String(format:"%08X",index))
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for name in ["capture.json","reference.html","PROMPT.txt"] { try Data("{}".utf8).write(to:folder.appendingPathComponent(name)) }
            try image.write(to:folder.appendingPathComponent("screenshot.png"))
        }
        let records = try CaptureCatalog.scan(root)
        XCTAssertEqual(records.count,200); XCTAssertTrue(records.allSatisfy { $0.problem == nil && $0.bytes == image.count+6 })
        XCTAssertEqual(records[0].expiration(days:1,now:Date(timeIntervalSince1970:1700086400)),"已到期，待清理")
        XCTAssertEqual(records[0].expiration(days:0),"永不过期")
    }
}
