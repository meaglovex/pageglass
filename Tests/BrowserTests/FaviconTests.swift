import AppKit
import XCTest
@testable import Browser

final class FaviconTests:XCTestCase {
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:48,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    }
    @MainActor func testDeclaredIconIsReusedByOtherBookmarkPathsWithoutNetwork() async throws {
        let data = try png(),page = URL(string:"https://pageglass.test/page?one#section")!,source = URL(string:"https://icons.pageglass.test/site.png")!
        var requested:[URL] = []
        let loader = FaviconLoader { requested.append($0);return $0 == source ? data : nil }
        let loaded = await loader.image(for:page,candidates:[source]),icon = try XCTUnwrap(loaded)
        let bookmark = URL(string:"https://pageglass.test/another/path")!
        XCTAssertTrue(loader.cached(for:bookmark) === icon)
        let reused = await loader.image(for:bookmark)
        XCTAssertTrue(reused === icon);XCTAssertEqual(requested,[source])
        XCTAssertEqual(icon.size,NSSize(width:16,height:12))
        XCTAssertTrue(icon.representations.allSatisfy { max($0.pixelsWide,$0.pixelsHigh) <= 32 })
    }
    @MainActor func testOnlyLeastRecentlyUsedOriginIsRemovedAtCapacity() async throws {
        let data = try png(),loader = FaviconLoader { _ in data }
        let pages = (0...128).map { URL(string:"https://site-\($0).pageglass.test/")! }
        for page in pages.prefix(128) { _ = await loader.image(for:page) }
        let recentlyUsed = try XCTUnwrap(loader.cached(for:pages[0]))
        _ = await loader.image(for:pages[128])
        XCTAssertNil(loader.cached(for:pages[1]))
        XCTAssertTrue(loader.cached(for:pages[0]) === recentlyUsed)
        for page in pages.dropFirst(2) { XCTAssertNotNil(loader.cached(for:page)) }
    }
    @MainActor func testReplacingAnOriginDoesNotEvictAnUnrelatedIcon() async throws {
        let data = try png(),loader = FaviconLoader { _ in data }
        let pages = (0..<128).map { URL(string:"https://site-\($0).pageglass.test/")! }
        for page in pages { _ = await loader.image(for:page) }
        let previous = try XCTUnwrap(loader.cached(for:pages[0]))
        let loaded = await loader.image(for:pages[0],candidates:[pages[0].appendingPathComponent("new-icon.png")]),replacement = try XCTUnwrap(loaded)
        XCTAssertFalse(previous === replacement)
        for page in pages { XCTAssertNotNil(loader.cached(for:page)) }
        XCTAssertTrue(loader.cached(for:pages[0]) === replacement)
    }
    @MainActor func testOriginSeparatesSchemePortAndHostAndRejectsLocalFiles() {
        let normal = URL(string:"https://pageglass.test/")!
        XCTAssertEqual(FaviconLoader.origin(URL(string:"https://user:secret@pageglass.test/a?q=1#part")!),normal)
        for value in ["http://pageglass.test/","https://pageglass.test:8443/","https://other.pageglass.test/"] {
            XCTAssertNotEqual(FaviconLoader.origin(URL(string:value)!),normal)
        }
        for value in ["file:///tmp/page.html","about:blank","data:text/html,test"] { XCTAssertNil(FaviconLoader.origin(URL(string:value)!)) }
    }
    @MainActor func testFailedReplacementKeepsTheLastWorkingIcon() async throws {
        let data = try png(),page = URL(string:"https://pageglass.test/")!,source = URL(string:"https://pageglass.test/good.png")!
        let loader = FaviconLoader { $0 == source ? data : Data("not an image".utf8) }
        let loaded = await loader.image(for:page,candidates:[source]),original = try XCTUnwrap(loaded)
        let afterFailure = await loader.image(for:page,candidates:[page.appendingPathComponent("bad.png")])
        XCTAssertTrue(afterFailure === original);XCTAssertTrue(loader.cached(for:page) === original)
    }
    @MainActor func testDiskCacheServesBookmarksAfterRelaunchWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let data = try png(),page = URL(string:"https://pageglass.test/docs")!
        let first = FaviconLoader(download:{ _ in data },disk:FaviconDiskCache(directory:directory,writable:true))
        _ = await first.image(for:page)
        var requested:[URL] = []
        let relaunched = FaviconLoader(download:{ requested.append($0);return nil },disk:FaviconDiskCache(directory:directory,writable:true))
        let cached = try XCTUnwrap(relaunched.cached(for:URL(string:"https://pageglass.test/other")!))
        XCTAssertEqual(cached.size,NSSize(width:16,height:12))
        let loaded = await relaunched.image(for:page)
        XCTAssertNotNil(loaded);XCTAssertEqual(requested,[])
        relaunched.clearDisk()
        XCTAssertNil(FaviconLoader(download:{ _ in nil },disk:FaviconDiskCache(directory:directory,writable:true)).cached(for:page))
    }
    @MainActor func testPrivateWindowsNeverWriteIconsToDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let data = try png(),loader = FaviconLoader(download:{ _ in data },disk:FaviconDiskCache(directory:directory,writable:false))
        _ = await loader.image(for:URL(string:"https://private.pageglass.test/")!)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    @MainActor func testPrivateWindowCanClearTheSharedIconStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let data = try png(),page = URL(string:"https://pageglass.test/")!
        _ = await FaviconLoader(download:{ _ in data },disk:FaviconDiskCache(directory:directory,writable:true)).image(for:page)
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.path))
        FaviconLoader(download:{ _ in nil },disk:FaviconDiskCache(directory:directory,writable:false)).clearDisk()
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path),"clearing shared history from a private window removes stored icons")
    }
    func testDiskCacheKeepsOnlyTheNewestIcons() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let image = try XCTUnwrap(NSImage(data:try png())?.cgImage(forProposedRect:nil,context:nil,hints:nil)),cache = FaviconDiskCache(directory:directory,writable:true)
        let origins = (0...FaviconDiskCache.limit).map { URL(string:"https://site-\($0).pageglass.test/")! }
        for (index,origin) in origins.enumerated() {
            cache.store(image,for:origin)
            if index == 0 { try FileManager.default.setAttributes([.modificationDate:Date.distantPast],ofItemAtPath:try FileManager.default.contentsOfDirectory(atPath:directory.path)[0].withDirectory(directory)) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).count,FaviconDiskCache.limit)
        XCTAssertNil(cache.image(for:origins[0]));XCTAssertNotNil(cache.image(for:origins.last!))
    }
}

private extension String { func withDirectory(_ directory:URL)->String { directory.appendingPathComponent(self).path } }
