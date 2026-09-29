import XCTest
@testable import Browser

final class NavigationTests: XCTestCase {
    func testAddressRouting() {
        XCTAssertEqual(Navigation.url(for:" example.com/path ")?.absoluteString,"https://example.com/path")
        XCTAssertEqual(Navigation.url(for:"localhost:3000/demo")?.absoluteString,"http://localhost:3000/demo")
        XCTAssertEqual(Navigation.url(for:"产品原型")?.host,"www.google.com")
        XCTAssertNil(Navigation.url(for:"javascript:alert(1)"))
        XCTAssertNil(Navigation.url(for:"data:text/html,hello"))
        XCTAssertNil(Navigation.url(for:"file:///etc/passwd"))
        XCTAssertNil(Navigation.url(for:""))
    }
}
