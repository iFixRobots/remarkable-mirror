/// A small, hard-bounded queue for host input waiting on the tablet transport.
///
/// Pointer motion is disposable under pressure. Release edges and reset are
/// safety events: a release always displaces less important work, and an
/// explicit or synthesized reset can replace a saturated queue of releases
/// because it releases every tablet-side input device at once.
struct TabletInputEventBuffer: Sendable {
    static let defaultMaximumCount = 64

    let maximumCount: Int
    private var pending: [TabletInputEvent] = []
    private var isUnderSaturationPressure = false

    init(maximumCount: Int = Self.defaultMaximumCount) {
        precondition(maximumCount > 0, "Input buffer capacity must be positive")
        self.maximumCount = maximumCount
    }

    var count: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ event: TabletInputEvent) {
        if Self.isReset(event) {
            replaceContentsWithReset()
            return
        }

        // Preserve the complete trajectory while there is room. Once the next
        // event would saturate the queue, retain an ordered sample of each move
        // run, including its first and latest positions, so a release does not
        // wait behind dozens of stale acknowledgements.
        if pending.count >= maximumCount - 1 {
            isUnderSaturationPressure = true
            compactPointerMovesForSaturation()
        }
        if isUnderSaturationPressure,
           let releaseKind = Self.pointerReleaseKind(event) {
            compactTrailingPointerMoves(kind: releaseKind)
        }

        guard pending.count >= maximumCount else {
            pending.append(event)
            return
        }

        if Self.isRelease(event) {
            var protectedMoveIndices = Self.finalMoveIndices(in: pending)
            if let currentFinalMove = Self.finalMoveIndex(
                in: pending,
                before: event
            ) {
                protectedMoveIndices.insert(currentFinalMove)
            }
            if let staleMoveIndex = pending.indices.first(
                where: {
                    !protectedMoveIndices.contains($0) &&
                        Self.pointerMoveKind(pending[$0]) != nil
                }
            ) {
                pending.remove(at: staleMoveIndex)
                pending.append(event)
            } else if let disposableIndex = pending.indices.first(
                where: {
                    !protectedMoveIndices.contains($0) &&
                        !Self.isSafetyEvent(pending[$0]) &&
                        !Self.isPointerDown(pending[$0])
                }
            ) {
                pending.remove(at: disposableIndex)
                pending.append(event)
            } else {
                // A reset is stronger than any collection of queued releases
                // and keeps the queue bounded even in the pathological case.
                replaceContentsWithReset()
            }
            return
        }

        let protectedMoveIndices = Self.finalMoveIndices(in: pending)
        guard let staleMoveIndex = pending.indices.first(
            where: {
                !protectedMoveIndices.contains($0) &&
                    Self.pointerMoveKind(pending[$0]) != nil
            }
        ) else {
            return
        }
        pending.remove(at: staleMoveIndex)
        pending.append(event)
    }

    mutating func dequeue() -> TabletInputEvent? {
        guard !pending.isEmpty else { return nil }
        let event = pending.removeFirst()
        if pending.isEmpty {
            isUnderSaturationPressure = false
        }
        return event
    }

    mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
        isUnderSaturationPressure = false
    }

    private mutating func replaceContentsWithReset() {
        pending.removeAll(keepingCapacity: true)
        pending.append(.reset)
        isUnderSaturationPressure = false
    }

    private mutating func compactPointerMovesForSaturation() {
        let moveLimit = representativeMoveLimit
        var compacted: [TabletInputEvent] = []
        compacted.reserveCapacity(pending.count)
        var start = pending.startIndex

        while start < pending.endIndex {
            guard let kind = Self.pointerMoveKind(pending[start]) else {
                compacted.append(pending[start])
                start += 1
                continue
            }

            var end = start + 1
            while end < pending.endIndex,
                  Self.pointerMoveKind(pending[end]) == kind {
                end += 1
            }
            appendRepresentativeMoves(
                from: start..<end,
                maximumCount: moveLimit,
                to: &compacted
            )
            start = end
        }

        pending = compacted
    }

    private mutating func compactTrailingPointerMoves(
        kind: PointerMoveKind
    ) {
        guard let lastIndex = pending.indices.last,
              Self.pointerMoveKind(pending[lastIndex]) == kind else {
            return
        }

        var start = lastIndex
        while start > pending.startIndex,
              Self.pointerMoveKind(pending[start - 1]) == kind {
            start -= 1
        }
        let range = start..<pending.endIndex
        guard range.count > representativeMoveLimit else { return }

        var compacted: [TabletInputEvent] = []
        compacted.reserveCapacity(representativeMoveLimit)
        appendRepresentativeMoves(
            from: range,
            maximumCount: representativeMoveLimit,
            to: &compacted
        )
        pending.replaceSubrange(range, with: compacted)
    }

    private var representativeMoveLimit: Int {
        min(8, max(1, maximumCount / 4))
    }

    private func appendRepresentativeMoves(
        from range: Range<Int>,
        maximumCount: Int,
        to output: inout [TabletInputEvent]
    ) {
        let count = range.count
        guard count > maximumCount else {
            output.append(contentsOf: pending[range])
            return
        }
        guard maximumCount > 1 else {
            output.append(pending[range.index(before: range.endIndex)])
            return
        }

        for sample in 0..<maximumCount {
            let offset = sample * (count - 1) / (maximumCount - 1)
            output.append(pending[range.lowerBound + offset])
        }
    }

    private static func isSafetyEvent(_ event: TabletInputEvent) -> Bool {
        isReset(event) || isRelease(event)
    }

    private static func isReset(_ event: TabletInputEvent) -> Bool {
        if case .reset = event {
            return true
        }
        return false
    }

    private static func isRelease(_ event: TabletInputEvent) -> Bool {
        switch event {
        case .touch(.up), .pen(.up), .key(action: .up, key: _):
            true
        default:
            false
        }
    }

    private static func isPointerDown(_ event: TabletInputEvent) -> Bool {
        switch event {
        case .touch(.down), .pen(.down): true
        default: false
        }
    }

    private enum PointerMoveKind: Equatable {
        case touch
        case pen
    }

    private static func finalMoveIndex(
        in events: [TabletInputEvent],
        before release: TabletInputEvent
    ) -> Int? {
        guard let releaseKind = pointerReleaseKind(release),
              let lastIndex = events.indices.last,
              pointerMoveKind(events[lastIndex]) == releaseKind else {
            return nil
        }
        return lastIndex
    }

    private static func finalMoveIndices(
        in events: [TabletInputEvent]
    ) -> Set<Int> {
        guard events.count > 1 else { return [] }

        var result: Set<Int> = []
        for index in events.indices.dropLast() {
            guard let kind = pointerMoveKind(events[index]),
                  pointerReleaseKind(events[index + 1]) == kind else {
                continue
            }
            result.insert(index)
        }
        return result
    }

    private static func pointerReleaseKind(
        _ event: TabletInputEvent
    ) -> PointerMoveKind? {
        switch event {
        case .touch(.up): .touch
        case .pen(.up): .pen
        default: nil
        }
    }

    private static func pointerMoveKind(
        _ event: TabletInputEvent
    ) -> PointerMoveKind? {
        switch event {
        case .touch(.move): .touch
        case .pen(.move): .pen
        default: nil
        }
    }
}
