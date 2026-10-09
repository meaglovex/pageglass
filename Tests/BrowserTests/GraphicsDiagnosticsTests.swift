import XCTest
@testable import Browser

final class GraphicsDiagnosticsTests:XCTestCase {
    func testContextAvailabilityAloneCannotPassDrawing() {
        let incomplete:[String:Any] = ["status":"passed","detail":"context created","renderer":"Apple GPU"]
        XCTAssertEqual(GraphicsCheck.parse(incomplete,api:"webgl2").status,.unknown)
        var wrong = incomplete; wrong["pixels"] = [0,0,0,0]
        XCTAssertEqual(GraphicsCheck.parse(wrong,api:"webgl2").status,.unknown)
        wrong["pixels"] = [Int.min,128,223,255]
        XCTAssertEqual(GraphicsCheck.parse(wrong,api:"webgl2").status,.unknown)
    }
    func testValidPixelReadbackAndComputeResultAreRequired() {
        let drawing:[String:Any] = ["status":"passed","detail":"drawn","renderer":"Apple GPU","pixels":[32,128,223,255]]
        XCTAssertEqual(GraphicsCheck.parse(drawing,api:"webgl2").status,.passed)
        XCTAssertEqual(GraphicsCheck.parse(drawing,api:"webgpu").status,.unknown)
        XCTAssertEqual(GraphicsCheck.parse(["status":"passed","detail":"computed","value":42],api:"webgpu").status,.passed)
        XCTAssertEqual(GraphicsCheck.parse(["status":"passed","detail":"computed","value":0],api:"webgpu").status,.unknown)
    }
    func testUnavailableFailureAndMissingDataRemainDistinct() {
        XCTAssertEqual(GraphicsCheck.parse(["status":"unavailable","detail":"no context"],api:"webgl").status,.unavailable)
        XCTAssertEqual(GraphicsCheck.parse(["status":"failed","detail":"shader failed"],api:"webgl").status,.failed)
        XCTAssertEqual(GraphicsCheck.parse(nil,api:"webgl").status,.unknown)
        XCTAssertEqual(GraphicsCheck.parse(["status":"invented","detail":""],api:"webgl").status,.unknown)
    }
    func testReportRetainsCapabilityScopeAndUnknownResults() throws {
        let unknown = GraphicsCheck(status:.unknown,detail:"not run")
        let report = GraphicsReport(sampledAt:Date(timeIntervalSince1970:0),appVersion:"test",appBuild:"test",osVersion:"test",accelerationPolicy:"automatic",devices:[],decoders:[.init(codec:"H.264",hardwareSupported:true)],webgl:unknown,webgl2:unknown,webgpu:unknown,scope:"capability only")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(GraphicsReport.self,from:Data(try XCTUnwrap(report.json).utf8))
        XCTAssertEqual(restored.webgl.status,.unknown)
        XCTAssertEqual(restored.scope,"capability only")
        XCTAssertTrue(restored.decoders[0].hardwareSupported)
    }
}
