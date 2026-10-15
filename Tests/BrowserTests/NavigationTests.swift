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
    func testLocalAddressesDefaultToHTTP() {
        XCTAssertEqual(Navigation.url(for:"192.168.1.10:8080/admin")?.absoluteString,"http://192.168.1.10:8080/admin")
        XCTAssertEqual(Navigation.url(for:"10.0.0.2")?.absoluteString,"http://10.0.0.2")
        XCTAssertEqual(Navigation.url(for:"[::1]:3000")?.absoluteString,"http://[::1]:3000")
        XCTAssertEqual(Navigation.url(for:"printer.local")?.absoluteString,"http://printer.local")
        XCTAssertEqual(Navigation.url(for:"app.localhost:5173")?.absoluteString,"http://app.localhost:5173")
        XCTAssertEqual(Navigation.url(for:"intranet:8080/wiki")?.absoluteString,"http://intranet:8080/wiki")
        XCTAssertEqual(Navigation.url(for:"example.com:8443")?.absoluteString,"https://example.com:8443")
    }
    func testVersionNumbersAndSingleWordsSearch() {
        for input in ["v1.2","3.14","1.2.3","intranet","999.1.1.1","a..b"] { XCTAssertEqual(Navigation.url(for:input)?.host,"www.google.com",input) }
    }
    func testAboutBlankAndExternalSchemes() {
        XCTAssertEqual(Navigation.url(for:"about:blank")?.absoluteString,"about:blank")
        XCTAssertEqual(Navigation.url(for:"mailto:someone@example.com")?.absoluteString,"mailto:someone@example.com")
        XCTAssertEqual(Navigation.url(for:"tel:+8610000000")?.scheme,"tel")
        XCTAssertEqual(Navigation.url(for:"about:config")?.host,"www.google.com")
    }
}
