import XCTest
@testable import Browser

final class StoreTests:XCTestCase {
    func testBookmarkEditPersistsIdentityAndRejectsInvalidAddress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BrowserStore(directory:directory)
        store.toggleBookmark(title:"原名称",url:"https://example.test/old")
        let original = try XCTUnwrap(store.state.bookmarks.first)
        XCTAssertFalse(store.updateBookmark(id:original.id,title:"不应保存",url:"javascript:alert(1)"))
        XCTAssertEqual(store.state.bookmarks.first,original)
        XCTAssertTrue(store.updateBookmark(id:original.id,title:" 修改后的名称 ",url:" https://example.test/new "))
        store.flush()
        let saved = try XCTUnwrap(BrowserStore(directory:directory).state.bookmarks.first)
        XCTAssertEqual(saved.id,original.id)
        XCTAssertEqual(saved.date,original.date)
        XCTAssertEqual(saved.title,"修改后的名称")
        XCTAssertEqual(saved.url,"https://example.test/new")
    }
    func testBookmarksHistorySettingsAndSessionSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BrowserStore(directory:directory)
        store.toggleBookmark(title:"产品文档",url:"https://example.test/docs")
        store.visit(title:"第一次",url:"https://example.test/docs")
        store.visit(title:"第二次",url:"https://example.test/docs")
        store.visit(title:"本地不计历史",url:"file:///tmp/test.html")
        var settings = BrowserSettings(); settings.searchEngine = "Bing"; settings.showBookmarksBar = true
        settings.appearance = "dark"; settings.toolbarTools = []; settings.autoCopyCapture = false
        store.updateSettings(settings)
        store.saveWindows([SavedWindow(tabs:[SavedTab(url:"https://example.test/docs",title:"文档"),SavedTab(url:nil,title:"新标签页")],active:1)])
        store.flush()
        let reopened = BrowserStore(directory:directory)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.state.bookmarks.count,1)
        XCTAssertEqual(reopened.state.history.count,1)
        XCTAssertEqual(reopened.state.history.first?.title,"第二次")
        XCTAssertEqual(reopened.state.settings.searchEngine,"Bing")
        XCTAssertEqual(reopened.state.settings.appearance,"dark"); XCTAssertEqual(reopened.state.settings.toolbarTools,[]); XCTAssertEqual(reopened.state.settings.autoCopyCapture,false)
        XCTAssertEqual(reopened.state.windows.first?.active,1)
        XCTAssertEqual(reopened.state.windows.first?.tabs.first?.title,"文档")
        XCTAssertEqual(reopened.suggestions("example").count,1)
        reopened.toggleBookmark(title:"",url:"https://example.test/docs"); reopened.flush()
        XCTAssertEqual(BrowserStore(directory:directory).state.bookmarks.count,0)
    }
    func testCorruptFileIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file = directory.appendingPathComponent("browser.json")
        try "unreadable original".write(to:file,atomically:true,encoding:.utf8)
        let store = BrowserStore(directory:directory)
        store.toggleBookmark(title:"new",url:"https://example.test"); store.flush()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"unreadable original")
    }
    func testDownloadStatusPersistsByIdentifier() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BrowserStore(directory:directory)
        var record = DownloadRecord(name:"test.txt",source:"https://example.test/test.txt")
        store.saveDownload(record); record.state = "已完成"; record.path = "/tmp/test.txt"; store.saveDownload(record); store.flush()
        let reopened = BrowserStore(directory:directory)
        XCTAssertEqual(reopened.state.downloads.count,1)
        XCTAssertEqual(reopened.state.downloads.first?.state,"已完成")
    }
    func testInterruptedDownloadDoesNotPretendToBeRunningAfterRestart() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BrowserStore(directory:directory)
        var record = DownloadRecord(name:"test.txt",source:"https://example.test/test.txt"); record.state = "下载中 42%"
        store.saveDownload(record); store.flush()
        XCTAssertEqual(BrowserStore(directory:directory).state.downloads.first?.state,"已中断：浏览器已退出")
    }
    func testLegacyPinnedTabsRestoreAsNormalTabsWithoutLosingPages() throws {
        let data = Data(#"{"tabs":[{"url":"https://example.test/keep","title":"保留页面","pinned":true}],"active":0}"#.utf8)
        let session = try JSONDecoder().decode(SavedWindow.self,from:data)
        XCTAssertEqual(session.tabs.first?.url,"https://example.test/keep")
        XCTAssertEqual(session.tabs.first?.title,"保留页面")
        let rewritten = try JSONEncoder().encode(session)
        XCTAssertFalse(String(decoding:rewritten,as:UTF8.self).contains("pinned"))
    }
    func testSearchEngineChoice() {
        XCTAssertEqual(Navigation.url(for:"产品 规划",searchEngine:"Bing")?.host,"www.bing.com")
        XCTAssertEqual(Navigation.url(for:"产品",searchEngine:"DuckDuckGo")?.host,"duckduckgo.com")
        XCTAssertEqual(URLComponents(url:Navigation.url(for:"产品",searchEngine:"百度")!,resolvingAgainstBaseURL:false)?.queryItems?.first?.name,"wd")
        XCTAssertEqual(Navigation.url(for:"https://example.test",searchEngine:"Bing")?.host,"example.test")
    }
}
