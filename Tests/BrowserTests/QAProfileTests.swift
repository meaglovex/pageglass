import XCTest
@testable import Browser

final class QAProfileTests:XCTestCase {
    private func directory()->URL { URL(fileURLWithPath:"/tmp/pageglass-profile-test-"+UUID().uuidString,isDirectory:true) }
    func testMarkedBundleRequiresAnExplicitProfile() throws {
        XCTAssertNil(try QAProfile.load(arguments:["Pageglass"],requiresIsolation:false))
        XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass"],requiresIsolation:true))
        XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass","--smoke","/tmp/test"],requiresIsolation:true))
        XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass","--qa-profile"],requiresIsolation:false))
        XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass","--qa-width","900"],requiresIsolation:false))
    }
    func testProfileIdentityIsStableAndInvalidOptionsHaveNoSideEffects() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at:path) }
        let args = ["Pageglass","--qa-profile",path.path]
        for tail in [["--qa-width","invalid"],["--qa-width","800"],["--qa-appearance","unknown"],["--qa-width"],["--qa-profile",path.path]] {
            XCTAssertThrowsError(try QAProfile.load(arguments:args+tail,requiresIsolation:true))
            XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        }
        let first = try XCTUnwrap(QAProfile.load(arguments:args+["--qa-width","900","--qa-appearance","DarkAqua"],requiresIsolation:true))
        let second = try XCTUnwrap(QAProfile.load(arguments:args,requiresIsolation:true))
        XCTAssertEqual(first.websiteDataID,second.websiteDataID)
        XCTAssertEqual(first.width,900); XCTAssertEqual(first.appearance,"DarkAqua")
    }
    func testRejectsNonTemporaryPathsAndIdentitySymlinks() throws {
        for path in ["relative/path","/","/tmp","/tmp/../Users","/private/tmp-other/test"] {
            XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass","--qa-profile",path],requiresIsolation:true))
        }
        let path = directory(); defer { try? FileManager.default.removeItem(at:path) }
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        let escape = path.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at:escape,withDestinationURL:URL(fileURLWithPath:"/Users",isDirectory:true))
        XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass","--qa-profile",escape.appendingPathComponent(UUID().uuidString).path],requiresIsolation:true))
        let identity = path.appendingPathComponent("website-data-id.txt")
        try FileManager.default.createSymbolicLink(at:identity,withDestinationURL:path.appendingPathComponent("missing.txt"))
        XCTAssertThrowsError(try QAProfile.load(arguments:["Pageglass","--qa-profile",path.path],requiresIsolation:true))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath:identity.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.appendingPathComponent("missing.txt").path))
    }
}
