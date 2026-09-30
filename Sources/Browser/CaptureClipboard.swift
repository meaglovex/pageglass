import AppKit

/// Automated capture checks use a private pasteboard; manual QA keeps the real handoff path.
enum CaptureClipboard {
    static let isAutomated = CommandLine.arguments.contains("--smoke")
    static let current:NSPasteboard = isAutomated ? .withUniqueName() : .general
    static func finishTesting() { if isAutomated { current.releaseGlobally() } }
}
