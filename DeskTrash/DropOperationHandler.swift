import Cocoa

final class DropOperationHandler {
    private let trashService: TrashService
    private let soundPlayer: SoundPlayer
    private let refreshTrashStatus: @MainActor () async -> Void

    init(
        trashService: TrashService,
        soundPlayer: SoundPlayer,
        refreshTrashStatus: @escaping @MainActor () async -> Void
    ) {
        self.trashService = trashService
        self.soundPlayer = soundPlayer
        self.refreshTrashStatus = refreshTrashStatus
    }

    func performDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }

        let classifiedItems = classify(items)
        moveFilesToTrash(classifiedItems.fileURLs)
        ejectVolumes(classifiedItems.volumeURLs, afterMovingFiles: !classifiedItems.fileURLs.isEmpty)
        scheduleTrashRefresh()
        return true
    }

    private func classify(_ items: [URL]) -> (fileURLs: [URL], volumeURLs: [URL]) {
        var fileURLs: [URL] = []
        var volumeURLs: [URL] = []

        for url in items {
            if trashService.isVolumeRoot(url: url) {
                volumeURLs.append(url)
            } else {
                fileURLs.append(url)
            }
        }

        return (fileURLs, volumeURLs)
    }

    private func moveFilesToTrash(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }

        for url in fileURLs {
            autoreleasepool {
                trashService.moveToTrash(url: url)
            }
        }

        soundPlayer.playDragToTrash()
    }

    private func ejectVolumes(_ volumeURLs: [URL], afterMovingFiles: Bool) {
        guard !volumeURLs.isEmpty else { return }

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let didEjectVolume = volumeURLs.contains { self.trashService.eject(volumeURL: $0) }

            guard didEjectVolume else { return }

            if afterMovingFiles {
                try? await Task.sleep(for: .milliseconds(150))
            }

            await MainActor.run {
                self.soundPlayer.playEject()
            }
        }
    }

    private func scheduleTrashRefresh() {
        Task { @MainActor [refreshTrashStatus] in
            try? await Task.sleep(for: .milliseconds(300))
            await refreshTrashStatus()
        }
    }
}
