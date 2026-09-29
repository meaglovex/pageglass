import XCTest
import CryptoKit
@testable import Browser

/// Opt-in check against a local 0.6 profile copy; never reads the real profile or logs its contents.
final class UpgradeCopyTests:XCTestCase {
    func testExistingProfileCopySurvivesSaveAndReload() throws {
        guard let path = ProcessInfo.processInfo.environment["PAGEGLASS_UPGRADE_COPY"] else { throw XCTSkip("Set PAGEGLASS_UPGRADE_COPY to an isolated profile copy") }
        let root = URL(fileURLWithPath:path,isDirectory:true)
        guard root.lastPathComponent.hasPrefix("upgrade-copy-"),FileManager.default.fileExists(atPath:root.appendingPathComponent("source-hashes.json").path) else { throw XCTSkip("Expected a prepared upgrade-copy directory with source hashes") }
        let file = root.appendingPathComponent("browser.json")
        let before = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        let store = BrowserStore(directory:root)
        XCTAssertTrue(store.error == nil,"Copied profile must decode before any write")
        store.flush()
        XCTAssertTrue(store.error == nil,"Copied profile must save")
        let after = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        func canonical(_ value:Any) throws->Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]) }
        for key in ["bookmarks","history","settings"] {
            // Only the equality result is reported; URLs, titles and settings stay local.
            XCTAssertTrue(try canonical(before[key]!) == canonical(after[key]!),"Existing \(key) changed during upgrade")
        }
        // The user removed tab pinning in 0.6. Only that retired field may disappear.
        let expectedWindows = (before["windows"] as? [[String:Any]] ?? []).map { window -> [String:Any] in
            var window = window
            window["tabs"] = (window["tabs"] as? [[String:Any]] ?? []).map { tab -> [String:Any] in
                var tab = tab; tab.removeValue(forKey:"pinned"); return tab
            }
            return window
        }
        XCTAssertTrue(try canonical(expectedWindows) == canonical(after["windows"]!),"Session changed beyond removal of retired pinning metadata")
        let reopened = BrowserStore(directory:root)
        XCTAssertTrue(reopened.error == nil,"Saved copy must reopen")
        let expectedDownloads = (before["downloads"] as? [[String:Any]] ?? []).map { item -> [String:Any] in
            var item = item
            if let state = item["state"] as? String,state.hasPrefix("下载中") || state == "等待保存" { item["state"] = "已中断：浏览器已退出" }
            return item
        }
        XCTAssertTrue(try canonical(expectedDownloads) == canonical(after["downloads"]!),"Download history changed beyond interrupted state normalization")
        let captures = root.appendingPathComponent("Captures",isDirectory:true)
        let packages = try CaptureRetention(root:captures).packages()
        var hashes:[URL:Data] = [:]
        for package in packages {
            for name in ["capture.json","reference.html","screenshot.png","PROMPT.txt"] {
                let url = package.url.appendingPathComponent(name)
                hashes[url] = Data(SHA256.hash(data:try Data(contentsOf:url)))
            }
        }
        let records = try CaptureCatalog.scan(captures)
        XCTAssertEqual(records.count,packages.count)
        for record in records {
            XCTAssertTrue(record.problem == nil,"Existing capture must remain readable")
            XCTAssertTrue(CaptureCatalog.thumbnail(record.directory) != nil,"Existing screenshot must decode")
        }
        for (url,hash) in hashes { XCTAssertTrue(Data(SHA256.hash(data:try Data(contentsOf:url))) == hash,"Reading a legacy capture must not rewrite it") }
    }
}
