import Foundation

protocol RouteGenerationControlling: Actor {
    nonisolated var id: GenerationID { get }
    nonisolated var route: ConnectionRoute { get }
    func retire() async throws
}

actor RouteGeneration: RouteGenerationControlling {
    nonisolated let id: GenerationID
    nonisolated let route: ConnectionRoute

    private let processRegistry: OwnedProcessRegistry
    private var retirementTask: Task<Void, Error>?
    private(set) var isRetired = false

    init(
        id: GenerationID,
        route: ConnectionRoute,
        processRegistry: OwnedProcessRegistry
    ) {
        self.id = id
        self.route = route
        self.processRegistry = processRegistry
    }

    func retire() async throws {
        if isRetired { return }
        if let retirementTask {
            return try await retirementTask.value
        }

        let task = Task { [processRegistry, id] in
            try await processRegistry.retire(generation: id)
        }
        retirementTask = task
        do {
            try await task.value
            isRetired = true
            retirementTask = nil
        } catch {
            retirementTask = nil
            throw error
        }
    }
}

struct RouteGenerationFactory: Sendable {
    let make: @Sendable (ConnectionRoute) async throws -> any RouteGenerationControlling

    init(_ make: @escaping @Sendable (ConnectionRoute) async throws -> any RouteGenerationControlling) {
        self.make = make
    }
}

enum DesiredRoute: Equatable, Sendable {
    case none
    case route(ConnectionRoute)
}

enum RouteLifecyclePublication: Equatable, Sendable {
    case cleared
    case activated(GenerationID, ConnectionRoute)
    case failed
}

enum RouteLifecycleError: Error, Equatable, Sendable {
    case transitionFailed
}

actor RouteGenerationLifecycle {
    private let factory: RouteGenerationFactory
    private let publish: @Sendable (RouteLifecyclePublication) async -> Void

    private var current: (any RouteGenerationControlling)?
    private var latestDesired: DesiredRoute?
    private var transitionWorker: Task<Void, Never>?
    private var activationPublication: (id: UUID, task: Task<Void, Never>)?
    private var transitionFailed = false
    private var isShuttingDown = false

    init(
        factory: RouteGenerationFactory,
        publish: @escaping @Sendable (RouteLifecyclePublication) async -> Void
    ) {
        self.factory = factory
        self.publish = publish
    }

    func request(_ desired: DesiredRoute) {
        guard !isShuttingDown else { return }
        activationPublication?.task.cancel()
        if transitionWorker == nil, latestDesired == nil {
            switch desired {
            case .none where current == nil:
                return
            case let .route(route) where current?.route == route && !transitionFailed:
                return
            default:
                break
            }
        }
        transitionFailed = false
        latestDesired = desired
        startWorkerIfNeeded()
    }

    func awaitSettled() async throws {
        while let worker = transitionWorker {
            await worker.value
        }
        if transitionFailed {
            throw RouteLifecycleError.transitionFailed
        }
    }

    func shutdown() async throws {
        isShuttingDown = true
        activationPublication?.task.cancel()
        transitionFailed = false
        latestDesired = DesiredRoute.none
        startWorkerIfNeeded()
        try await awaitSettled()
    }

    private func startWorkerIfNeeded() {
        guard transitionWorker == nil else { return }
        transitionWorker = Task { [self] in
            await runTransitionLoop()
        }
    }

    private func runTransitionLoop() async {
        while var desired = takeLatestDesired() {
            let didRetire = await retireCurrentGeneration()
            if !didRetire {
                latestDesired = nil
                break
            }

            if let newer = takeLatestDesired() {
                desired = newer
            }

            while case let .route(route) = desired {
                let candidate: any RouteGenerationControlling
                do {
                    candidate = try await factory.make(route)
                } catch {
                    transitionFailed = true
                    await publish(.failed)
                    break
                }

                if let newer = takeLatestDesired() {
                    do {
                        try await candidate.retire()
                    } catch {
                        transitionFailed = true
                        await publish(.failed)
                        break
                    }
                    desired = newer
                    continue
                }

                current = candidate
                let publicationID = UUID()
                let publication = RouteLifecyclePublication.activated(candidate.id, candidate.route)
                let publicationTask = Task { [publish] in
                    guard !Task.isCancelled else { return }
                    await publish(publication)
                }
                activationPublication = (publicationID, publicationTask)
                await publicationTask.value
                if activationPublication?.id == publicationID {
                    activationPublication = nil
                }
                break
            }
        }

        transitionWorker = nil
        if latestDesired != nil {
            startWorkerIfNeeded()
        }
    }

    private func retireCurrentGeneration() async -> Bool {
        guard let previous = current else { return true }
        activationPublication?.task.cancel()
        await publish(.cleared)
        do {
            try await previous.retire()
            if current?.id == previous.id {
                current = nil
            }
            return true
        } catch {
            transitionFailed = true
            await publish(.failed)
            return false
        }
    }

    private func takeLatestDesired() -> DesiredRoute? {
        let desired = latestDesired
        latestDesired = nil
        return desired
    }
}
