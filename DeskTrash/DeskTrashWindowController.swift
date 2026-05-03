import Cocoa

@MainActor
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class DeskTrashWindowController: NSObject, NSWindowDelegate {
    private let positionStore: WindowPositionStore
    private let windowSize = NSSize(width: 96, height: 96)

    let window: NSWindow

    init(positionStore: WindowPositionStore) {
        self.positionStore = positionStore

        let contentRect = NSRect(origin: positionStore.restoreOrigin(windowSize: windowSize), size: windowSize)
        let window = KeyableWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.window = window
        super.init()

        configureWindow(window)
        window.contentView = DropView(frame: NSRect(origin: .zero, size: windowSize))
        window.delegate = self
    }

    func showWindow() {
        window.orderFront(nil)
    }

    func windowDidMove(_ notification: Notification) {
        positionStore.save(origin: window.frame.origin)
    }

    private func configureWindow(_ window: NSWindow) {
        window.level = .normal
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
    }
}
