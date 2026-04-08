import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let windowController = DeskTrashWindowController(positionStore: WindowPositionStore())

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController.showWindow()
    }
}
