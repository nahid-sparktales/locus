import AppKit

private let application = NSApplication.shared
private let processController = RecoveryProcessController()
application.setActivationPolicy(.accessory)
processController.start()
application.run()
