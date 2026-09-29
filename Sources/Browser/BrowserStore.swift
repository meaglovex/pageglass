import Foundation

struct PageRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
}
struct DownloadRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var source: String
    var path: String?
    var state = "等待保存"
    var date = Date()
}
struct SavedTab: Codable { var url: String?; var title: String }
struct SavedWindow: Codable { var tabs: [SavedTab]; var active: Int }
struct BrowserSettings: Codable {
    var searchEngine = "Google"
    var homepage = ""
    var restoreSession = true
    var showBookmarksBar = false
    var defaultZoom = 1.0
    // Optional preserves older browser.json files; nil means never expire.
    var captureRetentionDays: Int? = nil
    var appearance:String? = nil
    var toolbarTools:[String]? = nil
    var autoCopyCapture:Bool? = nil
}

/// 仅保存浏览器功能数据；无痕窗口不写访问记录、下载记录和会话。
final class BrowserStore {
    static let shared = BrowserStore(directory:QAProfile.current?.directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Pageglass"))
    struct State: Codable {
        var bookmarks: [PageRecord] = []
        var history: [PageRecord] = []
        var downloads: [DownloadRecord] = []
        var windows: [SavedWindow] = []
        var settings = BrowserSettings()
    }
    private(set) var state = State()
    private(set) var error: String?
    private let file: URL
    private var saveWork: DispatchWorkItem?
    static let changed = Notification.Name("PageglassStoreChanged")

    init(directory:URL) {
        file = directory.appendingPathComponent("browser.json")
        if FileManager.default.fileExists(atPath:file.path) {
            do {
                state = try JSONDecoder().decode(State.self,from:Data(contentsOf:file))
                for i in state.downloads.indices where state.downloads[i].state.hasPrefix("下载中") || state.downloads[i].state == "等待保存" { state.downloads[i].state = "已中断：浏览器已退出" }
            }
            catch { self.error = "浏览器数据读取失败：\(error.localizedDescription)" }
        }
    }
    func bookmark(for url:String)->PageRecord? { state.bookmarks.first { $0.url == url } }
    func toggleBookmark(title:String,url:String) {
        if let i = state.bookmarks.firstIndex(where:{$0.url == url}) { state.bookmarks.remove(at:i) }
        else { state.bookmarks.insert(PageRecord(title:title,url:url),at:0) }
        changed()
    }
    @discardableResult
    func updateBookmark(id:UUID,title:String,url:String)->Bool {
        let address = url.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let parsed = URL(string:address),
              (parsed.isFileURL || (["http","https"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host?.isEmpty == false)),
              let index = state.bookmarks.firstIndex(where:{$0.id == id}) else { return false }
        let name = title.trimmingCharacters(in:.whitespacesAndNewlines)
        state.bookmarks[index].title = name.isEmpty ? address : name
        state.bookmarks[index].url = address
        changed();return true
    }
    func removeBookmark(id:UUID) { state.bookmarks.removeAll { $0.id == id }; changed() }
    func visit(title:String,url:String) {
        guard let parsed = URL(string:url), ["http","https"].contains(parsed.scheme?.lowercased() ?? "") else { return }
        if state.history.first?.url == url { state.history[0].date = Date(); state.history[0].title = title }
        else { state.history.insert(PageRecord(title:title,url:url),at:0) }
        if state.history.count > 10000 { state.history.removeLast(state.history.count-10000) }
        changed()
    }
    func updateHistoryTitle(url:String,title:String) {
        guard !title.isEmpty,let index = state.history.firstIndex(where:{$0.url == url}),state.history[index].title != title else { return }
        state.history[index].title = String(title.prefix(512)); changed()
    }
    func clearHistory() { state.history.removeAll(); changed() }
    func updateSettings(_ settings:BrowserSettings) { state.settings = settings; changed() }
    func saveWindows(_ windows:[SavedWindow]) { state.windows = windows; changed(notify:false) }
    func saveDownload(_ record:DownloadRecord) {
        if let i = state.downloads.firstIndex(where:{$0.id == record.id}) { state.downloads[i] = record }
        else { state.downloads.insert(record,at:0) }
        changed()
    }
    func suggestions(_ query:String)->[PageRecord] {
        let q = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return (state.bookmarks + state.history).filter { record in
            (record.title.localizedCaseInsensitiveContains(q) || record.url.localizedCaseInsensitiveContains(q)) && seen.insert(record.url).inserted
        }.prefix(8).map { $0 }
    }
    private func changed(notify:Bool = true) {
        if notify { NotificationCenter.default.post(name:Self.changed,object:self) }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    func flush() {
        // 读取失败时不覆盖无法解析的原文件。
        guard error == nil else { return }
        do {
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(state).write(to:file,options:.atomic)
        } catch { self.error = "浏览器数据保存失败：\(error.localizedDescription)" }
    }
}
