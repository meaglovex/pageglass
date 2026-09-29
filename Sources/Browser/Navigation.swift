import Foundation

/// 地址栏只接受网页地址；搜索词交给搜索引擎，不执行 javascript: 等协议。
enum Navigation {
    static func url(for input: String, searchEngine:String = "Google") -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil { return url }
        if text.contains("://") || text.lowercased().hasPrefix("javascript:") || text.lowercased().hasPrefix("data:") { return nil }
        if !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost") || text.hasPrefix("[::1]")) {
            let scheme = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasPrefix("[::1]") ? "http" : "https"
            return URL(string: "\(scheme)://\(text)")
        }
        let base: String
        switch searchEngine {
        case "Bing": base = "https://www.bing.com/search"
        case "DuckDuckGo": base = "https://duckduckgo.com/"
        case "百度": base = "https://www.baidu.com/s"
        default: base = "https://www.google.com/search"
        }
        var parts = URLComponents(string:base)!
        parts.queryItems = [URLQueryItem(name: searchEngine == "百度" ? "wd" : "q", value: text)]
        return parts.url
    }
}
