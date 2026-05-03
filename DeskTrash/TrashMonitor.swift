import Foundation

@MainActor
final class TrashMonitor {
    private let finderTrashService: FinderTrashService
    private let interval: TimeInterval
    private let onCountUpdate: @MainActor (Int) -> Void

    private var monitoringTask: Task<Void, Never>?
    private var isCheckingTrash = false
    private var previousTrashCount = -1
    private var nextAllowedCheckDate: Date?
    private var consecutiveFailures = 0

    init(
        finderTrashService: FinderTrashService,
        interval: TimeInterval = 6.0,
        onCountUpdate: @escaping @MainActor (Int) -> Void
    ) {
        self.finderTrashService = finderTrashService
        self.interval = interval
        self.onCountUpdate = onCountUpdate
    }

    deinit {
        monitoringTask?.cancel()
    }

    func start() {
        guard monitoringTask == nil else { return }

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

    func refresh() async {
        let now = Date()
        if let next = nextAllowedCheckDate, now < next {
            return
        }

        guard !isCheckingTrash else { return }
        isCheckingTrash = true

        let countResult = await finderTrashService.getTrashItemCount()
        isCheckingTrash = false
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
