import Foundation

@MainActor
final class TrashMonitor {
    private struct ActiveRefresh {
        let id: UInt
        let task: Task<Result<Int, FinderTrashServiceError>, Never>
    }

    private let getTrashItemCount: @Sendable () async -> Result<Int, FinderTrashServiceError>
    private let interval: TimeInterval
    private let onCountUpdate: @MainActor (Int) -> Void

    private var monitoringTask: Task<Void, Never>?
    private var activeRefresh: ActiveRefresh?
    private var nextRefreshID: UInt = 0
    private(set) var isSuspended = false
    private var previousTrashCount = -1
    private var nextAllowedCheckDate: Date?
    private var consecutiveFailures = 0

    init(
        finderTrashService: FinderTrashService,
        interval: TimeInterval = 6.0,
        onCountUpdate: @escaping @MainActor (Int) -> Void
    ) {
        self.getTrashItemCount = {
            await finderTrashService.getTrashItemCount()
        }
        self.interval = interval
        self.onCountUpdate = onCountUpdate
    }

    init(
        interval: TimeInterval = 6.0,
        getTrashItemCount: @escaping @Sendable () async -> Result<Int, FinderTrashServiceError>,
        onCountUpdate: @escaping @MainActor (Int) -> Void
    ) {
        self.getTrashItemCount = getTrashItemCount
        self.interval = interval
        self.onCountUpdate = onCountUpdate
    }

    deinit {
        monitoringTask?.cancel()
        activeRefresh?.task.cancel()
    }

    func start() {
        guard !isSuspended, monitoringTask == nil else { return }

        let interval = interval
        monitoringTask = Task { @MainActor [weak self] in
            await self?.refresh()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func suspendAndWait() async {
        isSuspended = true

        let monitoringTask = monitoringTask
        self.monitoringTask = nil
        monitoringTask?.cancel()

        let activeRefresh = activeRefresh
        activeRefresh?.task.cancel()

        if let activeRefresh {
            _ = await activeRefresh.task.value
            if self.activeRefresh?.id == activeRefresh.id {
                self.activeRefresh = nil
            }
        }

        if let monitoringTask {
            await monitoringTask.value
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        start()
    }

    func refresh() async {
        guard !isSuspended else { return }

        let now = Date()
        if let next = nextAllowedCheckDate, now < next {
            return
        }

        if let activeRefresh {
            _ = await activeRefresh.task.value
            return
        }

        nextRefreshID &+= 1
        let refreshID = nextRefreshID
        let task = Task { [getTrashItemCount] in
            await getTrashItemCount()
        }
        activeRefresh = ActiveRefresh(id: refreshID, task: task)

        let countResult = await task.value
        guard activeRefresh?.id == refreshID else { return }
        activeRefresh = nil
        guard !isSuspended, !task.isCancelled else { return }
        handle(result: countResult)
    }

    private func handle(result: Result<Int, FinderTrashServiceError>) {
        switch result {
        case .success(let count):
            consecutiveFailures = 0
            nextAllowedCheckDate = nil
            if count != previousTrashCount {
                previousTrashCount = count
                onCountUpdate(count)
            }
        case .failure:
            scheduleBackoff()
        }
    }

    private func scheduleBackoff() {
        consecutiveFailures += 1
        let delay: TimeInterval

        switch consecutiveFailures {
        case 1:
            delay = 30
        case 2:
            delay = 60
        default:
            delay = 300
        }

        nextAllowedCheckDate = Date().addingTimeInterval(delay)
    }
}
