import XCTest
import AppKit
@testable import Browser

final class CaptureRetentionTests:XCTestCase {
    func testExpiryPreservesRecentUnknownSymlinksAndFailedPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        func package(_ name:String)->URL {
            let url = root.appendingPathComponent(name)
            try! fm.createDirectory(at:url,withIntermediateDirectories:true)
            try! Data("{}".utf8).write(to:url.appendingPathComponent("capture.json"))
            return url
        }
        let old = package("1700000000-AAAAAAAA"), recent = package("1700086401-BBBBBBBB")
        let failed = package("1700000000-CCCCCCCC"), unknown = package("user-files")
        let link = root.appendingPathComponent("1700000000-DDDDDDDD")
        try fm.createSymbolicLink(at:link,withDestinationURL:unknown)
        let retention = CaptureRetention(root:root)
        XCTAssertEqual(try retention.packages().count,3)
        var removed:[URL] = []
        let now = Date(timeIntervalSince1970:1700086400)
        XCTAssertTrue(retention.clean(days:0,now:now,move:{ removed.append($0) }).removed.isEmpty)
        let result = retention.clean(days:1,now:now) { url in
            if url.lastPathComponent == failed.lastPathComponent { throw CocoaError(.fileWriteNoPermission) };removed.append(url)
        }
        XCTAssertEqual(result.removed.map(\.lastPathComponent),[old.lastPathComponent]);XCTAssertEqual(result.failures,1)
        XCTAssertFalse(removed.contains { $0.lastPathComponent == recent.lastPathComponent });XCTAssertFalse(removed.contains { $0.lastPathComponent == link.lastPathComponent })
        XCTAssertEqual(retention.clean(days:0,all:true,move:{ _ in }).removed.count,3)
    }
    func testLegacySettingsAndNewRetentionRoundTrip() throws {
        let legacy = Data(#"{"searchEngine":"Bing","homepage":"","restoreSession":true,"showBookmarksBar":true,"defaultZoom":1}"#.utf8)
        var settings = try JSONDecoder().decode(BrowserSettings.self,from:legacy)
        XCTAssertEqual(settings.searchEngine,"Bing");XCTAssertNil(settings.captureRetentionDays)
        settings.captureRetentionDays = 7
        XCTAssertEqual(try JSONDecoder().decode(BrowserSettings.self,from:JSONEncoder().encode(settings)).captureRetentionDays,7)
    }
    func testCleanupDoesNotClearUnrelatedClipboard() {
        let board = NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
        let removed = URL(fileURLWithPath:"/test/capture")
        board.setString("other app content",forType:.string)
        CaptureRetention.clearClipboard(for:[removed],pasteboard:board)
        XCTAssertEqual(board.string(forType:.string),"other app content")
        board.setString("/test/retained",forType:CaptureRetention.clipboardType)
        CaptureRetention.clearClipboard(for:[removed],pasteboard:board)
        XCTAssertNotNil(board.string(forType:.string))
        board.setString(removed.path,forType:CaptureRetention.clipboardType)
        CaptureRetention.clearClipboard(for:[removed],pasteboard:board)
        XCTAssertNil(board.string(forType:.string))
    }
}
