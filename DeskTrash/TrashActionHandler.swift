import Cocoa

@MainActor
final class TrashActionHandler {
    private let finderTrashService: FinderTrashService
    private let soundPlayer: SoundPlayer
    private let windowProvider: () -> NSWindow?
    private let logFinderAppleEventError: (FinderAppleEventFailure) -> Void
    private let operationCoordinator: TrashOperationCoordinator
    private let refreshTrashStatus: () async -> Void

    init(
        finderTrashService: FinderTrashService,
        soundPlayer: SoundPlayer,
        windowProvider: @escaping () -> NSWindow?,
        logFinderAppleEventError: @escaping (FinderAppleEventFailure) -> Void,
        operationCoordinator: TrashOperationCoordinator,
        refreshTrashStatus: @escaping () async -> Void
    ) {
        self.finderTrashService = finderTrashService
        self.soundPlayer = soundPlayer
        self.windowProvider = windowProvider
        self.logFinderAppleEventError = logFinderAppleEventError
        self.operationCoordinator = operationCoordinator
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let error = try await operationCoordinator.withExclusiveOperation {
                    await self.finderTrashService.openTrash()
                }
                if let error {
                    self.logFinderAppleEventError(error)
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func emptyTrashAfterConfirmation() async {
        guard let window = windowProvider() else { return }

        let alert = NSAlert()
        alert.messageText = "ゴミ箱を空にしますか？"
        alert.informativeText = "すべてのディスクのゴミ箱の内容が完全に削除されます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "空にする")

        let response = await alert.beginSheetModal(for: window)
        guard response == .alertSecondButtonReturn else {
            return
        }

        let error: FinderAppleEventFailure?
        do {
            error = try await operationCoordinator.withExclusiveOperation {
                await self.finderTrashService.emptyTrash()
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }

        if let error {
            await handleEmptyTrashFailure(error)
        } else {
            soundPlayer.playEmptyTrash()
        }

        await refreshTrashStatus()
    }

    private func handleEmptyTrashFailure(_ error: FinderAppleEventFailure) async {
        logFinderAppleEventError(error)

        guard let window = windowProvider() else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "ゴミ箱を空にできませんでした"
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        _ = await alert.beginSheetModal(for: window)
    }
}
