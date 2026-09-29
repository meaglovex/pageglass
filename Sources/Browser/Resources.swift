import Foundation

/// 优先读取 App 内资源；仅 swift run/test 时回退到 SwiftPM 的构建目录。
enum Resources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Pageglass_Browser.bundle"),
           let bundle = Bundle(url:url) { return bundle }
        return Bundle.module
    }()
}
