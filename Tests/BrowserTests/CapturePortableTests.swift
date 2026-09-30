import XCTest
import AppKit
@testable import Browser

final class CapturePortableTests:XCTestCase {
    private func create(_ folder:URL) throws {
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("assets"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("interaction-history"),withIntermediateDirectories:false)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        for name in ["screenshot.png","assets/resource-0.png","interaction-history/state-00.png"] { try png.write(to:folder.appendingPathComponent(name)) }
        for (index,ext) in ["avif","bmp","ico","woff2"].enumerated() { try Data("Owned format fixture \(ext)".utf8).write(to:folder.appendingPathComponent("assets/resource-\(index+1).\(ext)")) }
        let metadata:[String:Any] = ["title":"Owned fixture","mode":"page","url":"file:///Users/fixture/Private/path.html","assetManifest":[["file":"assets/resource-0.png","status":"bundled"]],"interactionHistory":["file":"interaction-history/timeline.json","steps":1]]
        try JSONSerialization.data(withJSONObject:metadata).write(to:folder.appendingPathComponent("capture.json"))
        try Data("<!doctype html><img src=\"assets/resource-0.png\"><p>Owned fixture</p>".utf8).write(to:folder.appendingPathComponent("reference.html"))
        try Data("<img src=\"../assets/resource-0.png\">".utf8).write(to:folder.appendingPathComponent("interaction-history/state-00.html"))
        try Data(#"{"steps":[{"screenshot":"state-00.png","html":"state-00.html"}]}"#.utf8).write(to:folder.appendingPathComponent("interaction-history/timeline.json"))
        try Data("Original local path: \(folder.path)".utf8).write(to:folder.appendingPathComponent("PROMPT.txt"))
        try Data("never export browser credentials".utf8).write(to:folder.appendingPathComponent("browser.json"))
        var edits = CaptureEdits(); edits.name = "整理名称"; edits.notes = "我的修改要求"; try edits.save(in:folder,expectedRevision:nil)
    }
    func testFolderRemainsReadableAfterMovingAndSourceRemovalWithoutLeakingProfilePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("1700000000-ABCDEF12"), destination = root.appendingPathComponent("portable")
        try create(source); let original = try Data(contentsOf:source.appendingPathComponent("capture.json"))
        try CapturePortable.export(source,to:destination,format:.folder)
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent("capture.json")),original)
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("browser.json").path))
        let metadata = try CaptureCatalog.metadata(in:destination)
        XCTAssertEqual(metadata["url"] as? String,"about:blank")
        let moved = root.appendingPathComponent("another-location")
        try FileManager.default.moveItem(at:destination,to:moved); try FileManager.default.removeItem(at:source)
        try CaptureCatalog.validate(moved)
        XCTAssertEqual(CaptureCatalog.record(moved).title,"整理名称")
        let prompt = try String(contentsOf:moved.appendingPathComponent("PROMPT.txt"),encoding:.utf8)
        XCTAssertFalse(prompt.contains(root.path)); XCTAssertTrue(prompt.contains("相对文件路径"))
        let html = try String(contentsOf:moved.appendingPathComponent("reference.html"),encoding:.utf8)
        XCTAssertTrue(html.contains("assets/resource-0.png")); XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:moved.appendingPathComponent("interaction-history/state-00.png").path))
        for (index,ext) in ["avif","bmp","ico","woff2"].enumerated() { XCTAssertEqual(try String(contentsOf:moved.appendingPathComponent("assets/resource-\(index+1).\(ext)"),encoding:.utf8),"Owned format fixture \(ext)") }
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:moved.appendingPathComponent("portable.json"))) as? [String:Any])
        XCTAssertEqual(report["format"] as? String,"pageglass-portable"); XCTAssertFalse((report["warnings"] as? [String] ?? []).isEmpty)
    }
    func testMissingRecordedAssetsAndInteractionFramesRemainExplicitInExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("1700000000-ABCDEF12"), target = root.appendingPathComponent("portable")
        try create(source)
        try FileManager.default.removeItem(at:source.appendingPathComponent("assets/resource-0.png"))
        try FileManager.default.removeItem(at:source.appendingPathComponent("interaction-history/state-00.png"))
        try CapturePortable.export(source,to:target,format:.folder)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:target.appendingPathComponent("portable.json"))) as? [String:Any])
        let warnings = report["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains{$0.contains("assets/resource-0.png")})
        XCTAssertTrue(warnings.contains{$0.contains("state-00.png")})
    }
    func testZIPExtractsWithSystemArchiveAndContainsRelativeCaptureFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("1700000000-ABCDEF12"), archive = root.appendingPathComponent("capture.zip"), extracted = root.appendingPathComponent("extracted")
        try create(source); try CapturePortable.export(source,to:archive,format:.zip)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/ditto"); process.arguments = ["-x","-k",archive.path,extracted.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        try CaptureCatalog.validate(extracted)
        XCTAssertTrue(FileManager.default.fileExists(atPath:extracted.appendingPathComponent("assets/resource-0.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:extracted.appendingPathComponent("browser.json").path))
        XCTAssertEqual(try CaptureEdits.load(in:extracted).notes,"我的修改要求")
    }
    func testSymlinkResourcesAndOverwriteFailWithoutLeavingPartialDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("1700000000-ABCDEF12"), target = root.appendingPathComponent("output"), asset = source.appendingPathComponent("assets/resource-0.png")
        try create(source)
        XCTAssertFalse(try CapturePortable.isOutsideCapture(source.appendingPathComponent("new-annotation.png"),source:source))
        XCTAssertFalse(try CapturePortable.isOutsideCapture(source.appendingPathComponent("screenshot.png"),source:source))
        XCTAssertThrowsError(try CapturePortable.export(source,to:source.appendingPathComponent("nested"),format:.folder))
        try Data("do not replace".utf8).write(to:target)
        XCTAssertThrowsError(try CapturePortable.export(source,to:target,format:.zip)); XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"do not replace")
        try FileManager.default.removeItem(at:target); try FileManager.default.removeItem(at:asset)
        try FileManager.default.createSymbolicLink(at:asset,withDestinationURL:source.appendingPathComponent("browser.json"))
        XCTAssertThrowsError(try CapturePortable.export(source,to:target,format:.folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".pageglass-export-")})
    }
}
