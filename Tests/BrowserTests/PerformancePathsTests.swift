import XCTest
import AppKit
import ImageIO
@testable import Browser

final class PerformancePathsTests:XCTestCase {
    func testSuggestionLimitPreservesRankingMatchingAndURLDeduplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var state = BrowserStore.State()
        state.bookmarks = [PageRecord(title:"Unrelated",url:"https://example.test/shared"),PageRecord(title:"Café 产品",url:"https://example.test/cafe")]
        state.history = [PageRecord(title:"匹配历史",url:"https://example.test/shared"),PageRecord(title:"Café 产品重复",url:"https://example.test/cafe")]
        state.history += (0..<100).map { PageRecord(title:"产品 \($0)",url:"https://example.test/item/\($0)") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(state).write(to:directory.appendingPathComponent("browser.json"))
        let store = BrowserStore(directory:directory)
        for input in ["产品"," CAFÉ ","匹配历史","example.test","does-not-match","", "   "] {
            let query = input.trimmingCharacters(in:.whitespacesAndNewlines)
            var seen = Set<String>()
            let expected = query.isEmpty ? [] : Array((state.bookmarks+state.history).filter {
                ($0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)) && seen.insert($0.url).inserted
            }.prefix(8))
            XCTAssertEqual(store.suggestions(input).map(\.id),expected.map(\.id),input)
        }
        XCTAssertEqual(store.suggestions("匹配历史").first?.title,"匹配历史")
    }

    @MainActor
    func testTabUpdateStillChangesTitleIconURLSelectionAndAccessibility() {
        let tab = BrowserTab(url:URL(string:"https://example.test/old")); tab.title = "原名称"
        let button = TabButton(tab:tab); button.update(tab,selected:false)
        button.needsDisplay = false
        button.update(tab,selected:false)
        XCTAssertFalse(button.needsDisplay,"unchanged tab must not request repaint")
        tab.title = "新名称"; tab.url = URL(string:"https://example.test/new")
        tab.favicon = NSImage(size:NSSize(width:16,height:16))
        button.update(tab,selected:true)
        XCTAssertEqual(button.accessibilityLabel(),"新名称")
        XCTAssertEqual(button.closeButton.accessibilityLabel(),"关闭 新名称")
        XCTAssertEqual(button.accessibilityValue() as? String,"当前标签页")
        XCTAssertEqual(button.toolTip,"新名称\nhttps://example.test/new")
        XCTAssertTrue(button.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === tab.favicon })
        tab.favicon = nil; tab.title = "";button.update(tab,selected:false)
        XCTAssertEqual(button.accessibilityLabel(),"新标签页")
        XCTAssertEqual(button.accessibilityValue() as? String,"")
        XCTAssertNotNil(button.subviews.compactMap { $0 as? NSImageView }.first?.image)
    }

    @MainActor
    func testPNGPreservesTransparentPixelsAndRetinaRasterSize() async throws {
        for scale in [1,2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16*scale,pixelsHigh:8*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    bitmap.setColor(NSColor(deviceRed:CGFloat(x%8)/7,green:CGFloat(y%8)/7,blue:0.5,alpha:x%3 == 0 ? 0 : x%3 == 1 ? 0.5 : 1),atX:x,y:y)
                }
            }
            bitmap.size = NSSize(width:16,height:8)
            let image = NSImage(size:bitmap.size);image.addRepresentation(bitmap)
            let oldBitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
            let original = try XCTUnwrap(oldBitmap.representation(using:.png,properties:[:]))
            let encoded = try await CapturePNG.encode(image)
            let legacyImage = try XCTUnwrap(NSImage(data:original)), optimizedImage = try XCTUnwrap(NSImage(data:encoded))
            XCTAssertEqual(optimizedImage.size.width,legacyImage.size.width,accuracy:0.01,"preserve PNG resolution metadata for native 100% preview")
            XCTAssertEqual(optimizedImage.size.height,legacyImage.size.height,accuracy:0.01)
            let before = try decode(original),after = try decode(encoded)
            XCTAssertEqual(after.width,16*scale);XCTAssertEqual(after.height,8*scale)
            XCTAssertEqual(before.width,after.width);XCTAssertEqual(before.height,after.height)
            XCTAssertEqual(before.rgba,after.rgba,"PNG optimization must preserve decoded pixels, including transparency")
        }
    }

    @MainActor
    func testPNGRejectsCancelledWork() async throws {
        let image = NSImage(size:NSSize(width:4,height:4))
        let task = Task { @MainActor in try await CapturePNG.encode(image) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled encoder returned data") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
    }

    private func decode(_ data:Data) throws -> (width:Int,height:Int,rgba:[UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let context = try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let pixels = try XCTUnwrap(context.data).bindMemory(to:UInt8.self,capacity:image.width*image.height*4)
        return (image.width,image.height,Array(UnsafeBufferPointer(start:pixels,count:image.width*image.height*4)))
    }
}
