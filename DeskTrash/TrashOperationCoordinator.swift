import Foundation

@MainActor
final class TrashOperationCoordinator {
    private struct Lease: Equatable {
        let id: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Lease, any Error>
    }

    private let suspendTrashMonitoring: @MainActor @Sendable () async -> Void
    private let resumeTrashMonitoring: @MainActor @Sendable () -> Void

    private var activeLease: Lease?
    private var waiters: [Waiter] = []
    private var nextLeaseID: UInt64 = 0

    var queuedOperationCount: Int {
        waiters.count
    }

    init(
        suspendTrashMonitoring: @escaping @MainActor @Sendable () async -> Void,
        resumeTrashMonitoring: @escaping @MainActor @Sendable () -> Void
    ) {
        self.suspendTrashMonitoring = suspendTrashMonitoring
        self.resumeTrashMonitoring = resumeTrashMonitoring
    }

    func withExclusiveOperation<Result>(
        _ operation: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        let lease = try await acquire()
        var didSuspendMonitoring = false

        defer {
            if didSuspendMonitoring {
                resumeTrashMonitoring()
            }
            release(lease)
        }

        try Task.checkCancellation()
        await suspendTrashMonitoring()
        didSuspendMonitoring = true
        try Task.checkCancellation()

        return try await operation()
    }

    private func acquire() async throws -> Lease {
        try Task.checkCancellation()
        let lease = makeLease()

        if activeLease == nil {
            activeLease = lease
            return lease
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: lease.id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: lease.id)
            }
        }
    }

    private func release(_ lease: Lease) {
        guard activeLease == lease else { return }

        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            let nextLease = Lease(id: waiter.id)
            activeLease = nextLease
            waiter.continuation.resume(returning: nextLease)
            return
        }

        activeLease = nil
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func makeLease() -> Lease {
        nextLeaseID &+= 1
        return Lease(id: nextLeaseID)
    }
}
