import XCTest
@testable import Browser

final class HTTPAuthenticationTests:XCTestCase {
    private func space(_ host:String = "intranet.example.test",port:Int = 443,scheme:String = "https",method:String = NSURLAuthenticationMethodHTTPBasic,realm:String? = "Admin")->URLProtectionSpace {
        URLProtectionSpace(host:host,port:port,protocol:scheme,realm:realm,authenticationMethod:method)
    }
    func testOnlyThePageOriginOrPendingNavigationMayPrompt() {
        let page = URL(string:"https://intranet.example.test/dashboard")
        XCTAssertTrue(HTTPAuthentication.shouldPrompt(space(),page:page,pending:nil,failures:0))
        XCTAssertTrue(HTTPAuthentication.shouldPrompt(space(),page:URL(string:"https://other.example.test/"),pending:page,failures:0),"navigation to a protected page")
        XCTAssertFalse(HTTPAuthentication.shouldPrompt(space("tracker.example.test"),page:page,pending:page,failures:0),"cross-origin subresource")
        XCTAssertFalse(HTTPAuthentication.shouldPrompt(space(port:8443),page:page,pending:nil,failures:0),"different port")
        XCTAssertFalse(HTTPAuthentication.shouldPrompt(space(scheme:"http",method:NSURLAuthenticationMethodHTTPBasic),page:page,pending:nil,failures:0),"different scheme")
        XCTAssertTrue(HTTPAuthentication.shouldPrompt(space("intranet.example.test",port:8080,scheme:"http"),page:URL(string:"http://INTRANET.example.test:8080/"),pending:nil,failures:0))
        XCTAssertTrue(HTTPAuthentication.shouldPrompt(space(port:80,scheme:"http"),page:URL(string:"http://intranet.example.test/"),pending:nil,failures:0),"default port")
    }
    func testTLSClientCertificatesKerberosAndRepeatedFailuresKeepDefaultHandling() {
        let page = URL(string:"https://intranet.example.test/")
        for method in [NSURLAuthenticationMethodServerTrust,NSURLAuthenticationMethodClientCertificate,NSURLAuthenticationMethodNegotiate] {
            XCTAssertFalse(HTTPAuthentication.shouldPrompt(space(method:method),page:page,pending:nil,failures:0),method)
        }
        XCTAssertTrue(HTTPAuthentication.shouldPrompt(space(method:NSURLAuthenticationMethodHTTPDigest),page:page,pending:nil,failures:4))
        XCTAssertFalse(HTTPAuthentication.shouldPrompt(space(),page:page,pending:nil,failures:HTTPAuthentication.maximumAttempts))
    }
    func testNoticeQuotesRealmAndWarnsOnPlainHTTP() {
        let secure = HTTPAuthentication.notice(space(realm:"  "+String(repeating:"区",count:300)+"\n"),failures:0)
        XCTAssertFalse(secure.contains("未加密")); XCTAssertFalse(secure.contains("不正确"))
        XCTAssertTrue(secure.contains("「"+String(repeating:"区",count:120)+"」"))
        let plain = HTTPAuthentication.notice(space(port:80,scheme:"http",realm:nil),failures:2)
        XCTAssertTrue(plain.contains("未加密") && plain.contains("不正确") && !plain.contains("网站提示"))
    }
}
