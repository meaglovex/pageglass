// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pageglass",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Pageglass", targets: ["Browser"])],
    targets: [
        .executableTarget(name: "Browser", resources: [.copy("Resources")]),
        .testTarget(name: "BrowserTests", dependencies: ["Browser"])
    ]
)
