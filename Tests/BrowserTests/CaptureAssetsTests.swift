import XCTest
@testable import Browser

@MainActor
final class CaptureAssetsTests:XCTestCase {
    private let nonce = "0123456789abcdef0123456789abcdef"
    private func token(_ index:Int)->String { "pageglass_asset_\(nonce)_\(index)_" }

    func testTokensWithSharedDigitPrefixesResolveIndependently() {
        let count = 23
        let references = (0..<count).map { ["url":"https://example.test/\($0).png","token":token($0),"context":$0 == 12 ? "css" : "html"] }
        var paths:[String:String] = [:]
        for index in 0..<count where index != 21 { paths["https://example.test/\(index).png"] = "assets/resource-\(index).png" }
        let html = (0..<count).map { "<img src=\"\(token($0))\">" }.joined()
        let output = CaptureAssets.resolve(html,references:references,paths:paths,prefix:"../")
        for index in 0..<count where index != 21 { XCTAssertTrue(output.contains("src=\"../assets/resource-\(index).png\""),"reference \(index)") }
        XCTAssertTrue(output.contains("src=\"https://example.test/21.png\""),"unsaved resource keeps its original URL")
        XCTAssertFalse(output.contains("pageglass_asset_"))
    }

    func testUnknownTokensAndSurroundingTextStayUnchanged() {
        let other = "pageglass_asset_ffffffffffffffffffffffffffffffff_1_"
        let html = "前 \(token(1)) 中 \(other) 后 \(token(1))"
        let output = CaptureAssets.resolve(html,references:[["url":"https://example.test/a\"b.png","token":token(1),"context":"html"]],paths:[:])
        XCTAssertEqual(output,"前 https://example.test/a&quot;b.png 中 \(other) 后 https://example.test/a&quot;b.png")
    }
}
