import Foundation

/// 地址栏只接受网页地址；搜索词交给搜索引擎，不执行 javascript: 等协议。
enum Navigation {
    /// Handed to another app after confirmation, never loaded in a tab.
    static let externalSchemes:Set<String> = ["mailto","tel","sms","facetime","facetime-audio"]

    static func url(for input: String, searchEngine:String = "Google") -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), url.host != nil { return url }
            if externalSchemes.contains(scheme) || text.lowercased() == "about:blank" { return url }
        }
        if text.contains("://") || text.lowercased().hasPrefix("javascript:") || text.lowercased().hasPrefix("data:") { return nil }
        if !text.contains(" "),let probe = URL(string:"http://\(text)"),let host = probe.host?.lowercased(),isAddress(host,port:probe.port) {
            return URL(string: "\(isLocal(host,port:probe.port) ? "http" : "https")://\(text)")
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

    /// A dotted name needs a top-level label with a letter, so "v1.2" or "3.14" is a search, not https://v1.2.
    private static func isAddress(_ host:String,port:Int?)->Bool {
        if host == "localhost" || isIPLiteral(host) { return true }
        let labels = host.split(separator:".",omittingEmptySubsequences:false)
        if labels.count == 1 { return port != nil && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        return labels.allSatisfy { !$0.isEmpty } && labels.last!.contains { $0.isLetter }
    }
    /// Development and LAN servers rarely have certificates; default them to http like localhost.
    private static func isLocal(_ host:String,port:Int?)->Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || isIPLiteral(host) || !host.contains(".")
    }
    private static func isIPLiteral(_ host:String)->Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator:".",omittingEmptySubsequences:false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && Int($0).map { (0...255).contains($0) } == true }
    }
}
