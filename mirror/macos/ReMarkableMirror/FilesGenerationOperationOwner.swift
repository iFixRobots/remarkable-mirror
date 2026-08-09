import Foundation

enum FilesGenerationOperationOwnerError: Error, Equatable, Sendable {
    case retired
}

enum FilesGenerationOperationOwnerState: Equatable, Sendable {
    case active
    case retiring
    case retired
}

/// Owns every user-triggered Files operation admitted for one connection
/// generation. Retirement is irreversible: it closes admission, cancels the
/// exact tasks already admitted, and does not finish until those tasks finish.
actor FilesGenerationOperationOwner {
    private struct InFlightOperation: Sendable {
        let cancel: @Sendable () -> Void
        let waitForCompletion: @Sendable () async -> Void

        init<Output: Sendable>(_ task: Task<Output, any Error>) {
            cancel = { task.cancel() }
            waitForCompletion = { _ = await task.result }
        }
    }

    private enum Lifecycle {
        case active
        case retiring(Task<Void, Never>)
        case retired
    }

    nonisolated let generation: GenerationID

    private var lifecycle = Lifecycle.active
    private var inFlight: [UUID: InFlightOperation] = [:]

    init(generation: GenerationID) {
        self.generation = generation
    }

    var state: FilesGenerationOperationOwnerState {
        switch lifecycle {
        case .active:
            .active
        case .retiring:
            .retiring
        case .retired:
            .retired
        }
    }

    var inFlightCount: Int {
        inFlight.count
    }

    /// Runs one operation only while this generation is active.
    ///
    /// The operation is wrapped in an owned task so retirement can cancel and
    /// drain it. The surrounding cancellation handler also forwards caller
    /// cancellation to that task. Cancellation is checked after the supplied
    /// closure returns so a closure that consumes cancellation cannot publish a
    /// successful result after either boundary has cancelled it.
    func run<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try Task.checkCancellation()
        guard case .active = lifecycle else {
            throw FilesGenerationOperationOwnerError.retired
        }

        let operationID = UUID()
        let task = Task<Output, any Error> {
            try Task.checkCancellation()
            do {
                let output = try await operation()
                try Task.checkCancellation()
                return output
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        inFlight[operationID] = InFlightOperation(task)
        defer { inFlight[operationID] = nil }

        let output = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return output
    }

    /// Permanently closes this owner. Concurrent callers share the same drain,
    /// and cancellation of a caller waiting here does not abandon retirement.
    func retire() async {
        let retirementTask: Task<Void, Never>
        switch lifecycle {
        case .active:
            let admittedOperations = Array(inFlight.values)
            admittedOperations.forEach { $0.cancel() }
            retirementTask = Task {
                for operation in admittedOperations {
                    await operation.waitForCompletion()
                }
            }
            lifecycle = .retiring(retirementTask)
        case let .retiring(existingTask):
            retirementTask = existingTask
        case .retired:
            return
        }

        await retirementTask.value
        // Admission is closed while retiring, so every remaining entry belongs
        // to the drained snapshot. A runner may not have resumed yet to execute
        // its own defer, but no underlying operation remains in progress.
        inFlight.removeAll(keepingCapacity: false)
        lifecycle = .retired
    }
}
