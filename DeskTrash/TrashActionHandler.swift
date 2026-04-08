import Cocoa

@MainActor
final class TrashActionHandler {
    private let finderTrashService: FinderTrashService
    private let soundPlayer: SoundPlayer
    private let windowProvider: () -> NSWindow?
    private let logAppleScriptError: (AppleScriptFailure) -> Void
    private let refreshTrashStatus: () async -> Void

    init(
        finderTrashService: FinderTrashService,
        soundPlayer: SoundPlayer,
        windowProvider: @escaping () -> NSWindow?,
        logAppleScriptError: @escaping (AppleScriptFailure) -> Void,
        refreshTrashStatus: @escaping () async -> Void
    ) {
        self.finderTrashService = finderTrashService
        self.soundPlayer = soundPlayer
        self.windowProvider = windowProvider
        self.logAppleScriptError = logAppleScriptError
        self.refreshTrashStatus = refreshTrashStatus
    }

    func makeContextMenu(target: AnyObject, emptyTrashAction: Selector, quitAction: Selector) -> NSMenu {
        let menu = NSMenu(title: "Context Menu")
        let emptyAllItem = NSMenuItem(title: "ゴミ箱を空にする", action: emptyTrashAction, keyEquivalent: "")
        emptyAllItem.target = target
        menu.addItem(emptyAllItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: quitAction, keyEquivalent: "")
        quitItem.target = target
        menu.addItem(quitItem)
        return menu
    }

    func openTrashFolder() {
        Task { [weak self] in
            guard let self else { return }
            if let error = await finderTrashService.openTrash() {
                await MainActor.run {
                    self.logAppleScriptError(error)
                }
            }
        }
    }

    func emptyTrashAfterConfirmation() async {
        guard let window = windowProvider() else { return }

        let alert = NSAlert()
        alert.messageText = "ゴミ箱を空にしますか？"
        alert.informativeText = "すべてのディスクのゴミ箱の内容が完全に削除されます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "空にする")
        alert.addButton(withTitle: "キャンセル")

        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else {
            return
        }

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let error = await self.finderTrashService.emptyTrash()

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let error {
                    self.logAppleScriptError(error)
                }
                self.soundPlayer.playEmptyTrash()
            }

            await self.refreshTrashStatus()
        }
    }
}
