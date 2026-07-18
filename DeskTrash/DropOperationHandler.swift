import Cocoa

struct VolumeUnmountBatchResult: Sendable {
    let results: [VolumeUnmountResult]
    let lookupFailures: [ItemLookupFailure]

    var didEjectVolume: Bool {
        results.contains { result in
            if case .success = result {
                return true
            }
            return false
        }
    }

    var unmountFailures: [VolumeUnmountFailure] {
        results.compactMap { result in
            guard case .failure(let failure) = result else {
                return nil
            }
            return failure
        }
    }
}

@MainActor
final class DropOperationHandler {
    private let trashService: TrashService
    private let soundPlayer: SoundPlayer
    private let refreshTrashStatus: @MainActor @Sendable () async -> Void
    private let operationCoordinator: TrashOperationCoordinator
    private let reportDropFailures: @MainActor @Sendable (
        Int,
        [ItemLookupFailure],
        [VolumeUnmountFailure]
    ) -> Void
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
        operationCoordinator: TrashOperationCoordinator,
        reportDropFailures: @escaping @MainActor @Sendable (
            Int,
            [ItemLookupFailure],
            [VolumeUnmountFailure]
        ) -> Void
    ) {
        self.trashService = trashService
        self.soundPlayer = soundPlayer
        self.refreshTrashStatus = refreshTrashStatus
        self.operationCoordinator = operationCoordinator
        self.reportDropFailures = reportDropFailures
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

            guard let result = await self.processDrop(items) else { return }
            guard !Task.isCancelled else { return }

            await self.handleDropResult(result)
        }
        return true
    }

    private nonisolated struct ClassifiedItems: Sendable {
        let fileURLs: [URL]
        let volumeTargets: [VolumeTarget]
        let lookupFailures: [ItemLookupFailure]
    }

    private nonisolated struct FileMoveResult: Sendable {
        let didMoveFile: Bool
        let failedCount: Int
    }

    nonisolated struct DropOperationResult: Sendable {
        let didMoveFile: Bool
        let failedMoveCount: Int
        let volumeBatchResult: VolumeUnmountBatchResult

        var didEjectVolume: Bool {
            volumeBatchResult.didEjectVolume
        }

        var volumeUnmountFailures: [VolumeUnmountFailure] {
            volumeBatchResult.unmountFailures
        }

        var shouldRefreshTrashStatus: Bool {
            didMoveFile || didEjectVolume
        }
    }

    func processDrop(_ items: [URL]) async -> DropOperationResult? {
        let classifiedItems = await Self.classify(items, trashService: trashService)
        guard !Task.isCancelled else { return nil }

        let moveResult = await Self.moveFilesToTrash(classifiedItems.fileURLs, trashService: trashService)
        guard !Task.isCancelled else { return nil }

        var volumeBatchResult = VolumeUnmountBatchResult(
            results: [],
            lookupFailures: classifiedItems.lookupFailures
        )
        if !classifiedItems.volumeTargets.isEmpty {
            do {
                let unmountResult = try await operationCoordinator.withExclusiveOperation {
                    await Self.ejectVolumes(
                        classifiedItems.volumeTargets,
                        trashService: self.trashService
                    )
                }
                volumeBatchResult = VolumeUnmountBatchResult(
                    results: unmountResult.results,
                    lookupFailures: classifiedItems.lookupFailures + unmountResult.lookupFailures
                )
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }

        return DropOperationResult(
            didMoveFile: moveResult.didMoveFile,
            failedMoveCount: moveResult.failedCount,
            volumeBatchResult: volumeBatchResult
        )
    }

    private nonisolated static func classify(_ items: [URL], trashService: TrashService) async -> ClassifiedItems {
        let task = Task.detached(priority: .userInitiated) {
            var fileURLs: [URL] = []
            var volumeTargets: [VolumeTarget] = []
            var lookupFailures: [ItemLookupFailure] = []
            var seenMountPaths: Set<String> = []

            for url in items {
                guard !Task.isCancelled else { break }
                switch trashService.classifyItem(at: url) {
                case .file(let fileURL):
                    fileURLs.append(fileURL)
                case .volume(let target):
                    if seenMountPaths.insert(target.canonicalMountPath).inserted {
                        volumeTargets.append(target)
                    }
                case .lookupFailed(let failure):
                    lookupFailures.append(failure)
                }
            }

            return ClassifiedItems(
                fileURLs: fileURLs,
                volumeTargets: volumeTargets,
                lookupFailures: lookupFailures
            )
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func moveFilesToTrash(_ fileURLs: [URL], trashService: TrashService) async -> FileMoveResult {
        guard !fileURLs.isEmpty else {
            return FileMoveResult(didMoveFile: false, failedCount: 0)
        }

        let task = Task.detached(priority: .userInitiated) {
            var didMoveFile = false
            var failedCount = 0

            for url in fileURLs {
                guard !Task.isCancelled else { break }
                let didMove = autoreleasepool {
                    trashService.moveToTrash(url: url)
                }

                if didMove {
                    didMoveFile = true
                } else {
                    failedCount += 1
                }
            }

            return FileMoveResult(didMoveFile: didMoveFile, failedCount: failedCount)
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func ejectVolumes(
        _ volumeTargets: [VolumeTarget],
        trashService: TrashService
    ) async -> VolumeUnmountBatchResult {
        var results: [VolumeUnmountResult] = []
        var lookupFailures: [ItemLookupFailure] = []
        results.reserveCapacity(volumeTargets.count)

        for volume in volumeTargets {
            guard !Task.isCancelled else { break }

            let result = await trashService.eject(volume: volume)
            if case .lookupFailed(let failure) = result {
                lookupFailures.append(failure)
            } else {
                results.append(result)
            }
        }

        return VolumeUnmountBatchResult(results: results, lookupFailures: lookupFailures)
    }

    private func handleDropResult(_ result: DropOperationResult) async {
        reportFailures(for: result)

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

    func reportFailures(for result: DropOperationResult) {
        let lookupFailures = result.volumeBatchResult.lookupFailures
        let volumeFailures = result.volumeUnmountFailures
        guard result.failedMoveCount > 0 || !lookupFailures.isEmpty || !volumeFailures.isEmpty else {
            return
        }
        reportDropFailures(result.failedMoveCount, lookupFailures, volumeFailures)
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
