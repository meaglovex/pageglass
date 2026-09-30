import AppKit

// Resolve isolation before creating an application delegate or opening any store.
_ = QAProfile.current

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
