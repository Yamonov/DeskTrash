import Cocoa

@MainActor
final class DropOperationHandler {
    private let trashService: TrashService
    private let soundPlayer: SoundPlayer
    private let refreshTrashStatus: @MainActor @Sendable () async -> Void
    private let reportDropFailure: @MainActor @Sendable (Int) -> Void
    private var isProcessingDrop = false
    private var dropTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var canAcceptDrop: Bool {
        !isProcessingDrop
    }

    init(
        trashService: TrashService,
        soundPlayer: SoundPlayer,
        refreshTrashStatus: @escaping @MainActor @Sendable () async -> Void,
        reportDropFailure: @escaping @MainActor @Sendable (Int) -> Void
    ) {
        self.trashService = trashService
        self.soundPlayer = soundPlayer
        self.refreshTrashStatus = refreshTrashStatus
        self.reportDropFailure = reportDropFailure
    }

    deinit {
        dropTask?.cancel()
        refreshTask?.cancel()
    }

    func performDrop(from pasteboard: NSPasteboard) -> Bool {
        guard !isProcessingDrop else {
            return false
        }

        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !items.isEmpty else {
            return false
        }

        isProcessingDrop = true
        dropTask = Task { @MainActor [weak self] in
            await Task.yield()

            guard let self else { return }
            defer {
                self.isProcessingDrop = false
                self.dropTask = nil
            }

            guard !Task.isCancelled else { return }

            let result = await Self.processDrop(items, trashService: self.trashService)
            guard !Task.isCancelled else { return }

            await self.handleDropResult(result)
        }
        return true
    }

    private nonisolated struct DropOperationResult: Sendable {
        let didMoveFile: Bool
        let failedMoveCount: Int
        let didEjectVolume: Bool
        let shouldRefreshTrashStatus: Bool
    }

    private nonisolated static func processDrop(_ items: [URL], trashService: TrashService) async -> DropOperationResult {
        await Task.detached(priority: .userInitiated) {
            let classifiedItems = classify(items, trashService: trashService)
            let moveResult = moveFilesToTrash(classifiedItems.fileURLs, trashService: trashService)
            let didEjectVolume = ejectVolumes(classifiedItems.volumeURLs, trashService: trashService)
            let shouldRefreshTrashStatus = moveResult.didMoveFile || didEjectVolume

            return DropOperationResult(
                didMoveFile: moveResult.didMoveFile,
                failedMoveCount: moveResult.failedCount,
                didEjectVolume: didEjectVolume,
                shouldRefreshTrashStatus: shouldRefreshTrashStatus
            )
        }.value
    }

    private nonisolated static func classify(_ items: [URL], trashService: TrashService) -> (fileURLs: [URL], volumeURLs: [URL]) {
        var fileURLs: [URL] = []
        var volumeURLs: [URL] = []
        let volumeRoots = trashService.mountedVolumeRoots()

        for url in items {
            if trashService.isVolumeRoot(url: url, mountedVolumeRoots: volumeRoots) {
                volumeURLs.append(url)
            } else {
                fileURLs.append(url)
            }
        }

        return (fileURLs, volumeURLs)
    }

    private nonisolated static func moveFilesToTrash(_ fileURLs: [URL], trashService: TrashService) -> (didMoveFile: Bool, failedCount: Int) {
        guard !fileURLs.isEmpty else {
            return (false, 0)
        }

        var didMoveFile = false
        var failedCount = 0

        for url in fileURLs {
            let didMove = autoreleasepool {
                trashService.moveToTrash(url: url)
            }

            if didMove {
                didMoveFile = true
            } else {
                failedCount += 1
            }
        }

        return (didMoveFile, failedCount)
    }

    private nonisolated static func ejectVolumes(_ volumeURLs: [URL], trashService: TrashService) -> Bool {
        guard !volumeURLs.isEmpty else {
            return false
        }

        var didEjectVolume = false
        for url in volumeURLs {
            if trashService.eject(volumeURL: url) {
                didEjectVolume = true
            }
        }

        return didEjectVolume
    }

    private func handleDropResult(_ result: DropOperationResult) async {
        if result.failedMoveCount > 0 {
            reportDropFailure(result.failedMoveCount)
        }

        if result.didMoveFile {
            soundPlayer.playDragToTrash()
        }

        if result.didEjectVolume {
            if result.didMoveFile {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            soundPlayer.playEject()
        }

        if result.shouldRefreshTrashStatus {
            scheduleTrashRefresh()
        }
    }

    private func scheduleTrashRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self, refreshTrashStatus] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshTrashStatus()
            self?.refreshTask = nil
        }
    }
}
