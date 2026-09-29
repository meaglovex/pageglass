import XCTest
import AppKit
@testable import Browser

final class CaptureEditsTests:XCTestCase {
    private func fixture(in root:URL)->URL { root.appendingPathComponent("1700000000-ABCDEF12") }
    private func create(_ directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:160,pixelsHigh:120,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("screenshot.png"))
        try Data(#"{"title":"原网页","url":"https://example.test/capture","mode":"element"}"#.utf8).write(to:directory.appendingPathComponent("capture.json"))
        try Data("<p>Original page evidence</p>".utf8).write(to:directory.appendingPathComponent("reference.html"))
        try Data("Local capture: \(directory.path)".utf8).write(to:directory.appendingPathComponent("PROMPT.txt"))
    }
    func testSavedEditsReopenSearchAndHandoffWithoutChangingOriginalEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = fixture(in:root)
        defer { try? FileManager.default.removeItem(at:root) }; try create(folder)
        let names = ["screenshot.png","reference.html","capture.json","PROMPT.txt"]
        let original = try names.map { try Data(contentsOf:folder.appendingPathComponent($0)) }
        var edits = try CaptureEdits.load(in:folder); XCTAssertNil(edits.revision)
        edits.name = "审核按钮"; edits.notes = "在右侧增加查看详情"
        edits.annotations = [CaptureAnnotation(kind:.rectangle,x:0.1,y:0.2,endX:0.7,endY:0.8),CaptureAnnotation(kind:.text,x:0.15,y:0.3,endX:0.15,endY:0.3,text:"新增按钮")]
        let saved = try edits.save(in:folder,expectedRevision:nil)
        XCTAssertNotNil(saved.revision); XCTAssertEqual(try CaptureEdits.load(in:folder),saved)
        let record = CaptureCatalog.record(folder)
        XCTAssertNil(record.problem); XCTAssertNil(record.editProblem); XCTAssertEqual(record.title,"审核按钮"); XCTAssertEqual(record.originalTitle,"原网页")
        XCTAssertTrue(CaptureRecordFilter.matches(record,query:"查看详情",mode:"element",since:Date(timeIntervalSince1970:1699999999)))
        XCTAssertTrue(CaptureRecordFilter.matches(record,query:"原网页")); XCTAssertFalse(CaptureRecordFilter.matches(record,query:"审核",mode:"page"))
        XCTAssertFalse(CaptureRecordFilter.matches(record,query:"",since:Date(timeIntervalSince1970:1700000001)))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try CaptureCatalog.copyPrompt(folder,pasteboard:board)
        XCTAssertTrue(board.string(forType:.string)?.contains("pageglass.json") == true)
        XCTAssertTrue(board.string(forType:.string)?.contains("在右侧增加查看详情") == true)
        XCTAssertEqual(try names.map { try Data(contentsOf:folder.appendingPathComponent($0)) },original)
    }
    func testConcurrentEditsRefuseStaleSaveAndCorruptOrFutureFilesRemainIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = fixture(in:root)
        defer { try? FileManager.default.removeItem(at:root) }; try create(folder)
        let first = try CaptureEdits.load(in:folder); var second = first; second.notes = "new edit"
        let saved = try second.save(in:folder,expectedRevision:nil)
        XCTAssertThrowsError(try first.save(in:folder,expectedRevision:nil))
        XCTAssertEqual(try CaptureEdits.load(in:folder),saved)
        let sidecar = folder.appendingPathComponent(CaptureEdits.filename)
        var future = saved; future.version = 2
        for invalid in [Data("broken-json".utf8),try JSONEncoder().encode(future)] {
            try invalid.write(to:sidecar)
            XCTAssertThrowsError(try CaptureEdits.load(in:folder)); XCTAssertThrowsError(try first.save(in:folder,expectedRevision:saved.revision))
            XCTAssertEqual(try Data(contentsOf:sidecar),invalid)
            XCTAssertNil(CaptureCatalog.record(folder).problem); XCTAssertNotNil(CaptureCatalog.record(folder).editProblem)
        }
    }
    func testSymlinksSpecialFilesLimitsAndMissingCaptureCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = fixture(in:root)
        defer { try? FileManager.default.removeItem(at:root) }; try create(folder)
        let outside = root.appendingPathComponent("keep.txt"), sidecar = folder.appendingPathComponent(CaptureEdits.filename)
        try Data("keep".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:sidecar,withDestinationURL:outside)
        XCTAssertThrowsError(try CaptureEdits.load(in:folder)); XCTAssertThrowsError(try CaptureEdits().save(in:folder,expectedRevision:nil))
        XCTAssertEqual(try String(contentsOf:outside,encoding:.utf8),"keep")
        try FileManager.default.removeItem(at:sidecar); try FileManager.default.createDirectory(at:sidecar,withIntermediateDirectories:false)
        XCTAssertThrowsError(try CaptureEdits.load(in:folder)); XCTAssertThrowsError(try CaptureEdits().save(in:folder,expectedRevision:nil))
        try FileManager.default.removeItem(at:sidecar)
        var invalid = CaptureEdits(); invalid.notes = String(repeating:"a",count:8001); XCTAssertThrowsError(try invalid.save(in:folder,expectedRevision:nil))
        invalid = CaptureEdits(); invalid.annotations = [CaptureAnnotation(kind:.arrow,x:0,y:.infinity,endX:1,endY:1)]; XCTAssertThrowsError(try invalid.validate())
        invalid.annotations[0].y = -0.1; XCTAssertThrowsError(try invalid.validate())
        invalid.annotations[0].y = 0; invalid.annotations.append(invalid.annotations[0]); XCTAssertThrowsError(try invalid.validate())
        try FileManager.default.removeItem(at:folder.appendingPathComponent("screenshot.png"))
        XCTAssertThrowsError(try CaptureEdits().save(in:folder,expectedRevision:nil)); XCTAssertFalse(FileManager.default.fileExists(atPath:sidecar.path))
    }
    func testAnnotationMovementPreservesDimensionsAndStaysInScreenshot() {
        let mark = CaptureAnnotation(kind:.rectangle,x:0.2,y:0.3,endX:0.5,endY:0.6)
        let left = mark.moved(dx:-10,dy:-10), right = mark.moved(dx:10,dy:10)
        XCTAssertEqual(left.x,0,accuracy:0.00001); XCTAssertEqual(left.y,0,accuracy:0.00001)
        XCTAssertEqual(right.endX,1,accuracy:0.00001); XCTAssertEqual(right.endY,1,accuracy:0.00001)
        XCTAssertEqual(left.bounds.width,mark.bounds.width,accuracy:0.00001); XCTAssertEqual(right.bounds.height,mark.bounds.height,accuracy:0.00001)
    }
}
