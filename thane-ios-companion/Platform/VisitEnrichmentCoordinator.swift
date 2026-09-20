import Foundation

@MainActor
protocol VisitPlaceResolving: Sendable {
    var provider: String { get }
    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext
}

/// Enriches stored visits without extending capture or upload lifetimes.
@Observable
@MainActor
final class VisitEnrichmentCoordinator {
    private(set) var isResolving = false
    private(set) var lastError: String?

    private let store: VisitWindowStore
    private let currentScope: @MainActor () -> String?
    private let prepareLookup: @MainActor (VisitWindowSnapshot) async throws -> Void
    private let publish: @MainActor (VisitWindowSnapshot) -> Void
    private let now: @MainActor () -> Date
    private let timeout: Duration
    private var resolver: (any VisitPlaceResolving)?
    private var scope: String?
    private var generation = UUID()
    private var worker: Task<Void, Never>?

    init(
        store: VisitWindowStore,
        currentScope: @escaping @MainActor () -> String?,
        prepareLookup: @escaping @MainActor (VisitWindowSnapshot) async throws -> Void,
        publish: @escaping @MainActor (VisitWindowSnapshot) -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        timeout: Duration = .seconds(20)
    ) {
        self.store = store
        self.currentScope = currentScope
        self.prepareLookup = prepareLookup
        self.publish = publish
        self.now = now
        self.timeout = timeout
    }

    func configure(scope: String, resolver: any VisitPlaceResolving) {
        invalidate()
        guard currentScope() == scope else { return }
        self.scope = scope
        self.resolver = resolver
        resume()
    }

    /// Invalidates completions even when the underlying request ignores cancellation.
    func invalidate() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        resolver = nil
        scope = nil
        isResolving = false
        lastError = nil
    }

    /// Called on a visit or an existing foreground/wake opportunity, never a timer.
    func resume() {
        guard worker == nil, let scope, let resolver, currentScope() == scope else { return }
        let generation = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await process(scope: scope, resolver: resolver, generation: generation)
            guard self.generation == generation else { return }
            worker = nil
            isResolving = false
        }
    }

    private func process(
        scope: String, resolver: any VisitPlaceResolving, generation: UUID
    ) async {
        var attempted = Set<UUID>()
        while permitsCompletion(scope: scope, generation: generation) {
            guard let visit = store.window(now: now()).visits.first(where: {
                !attempted.contains($0.visitID) && needsLookup($0, provider: resolver.provider, at: now())
            }) else { return }
            isResolving = true
            do {
                let window = try store.persistCurrentWindow(now: now())
                try await prepareLookup(window)
            } catch {
                guard permitsCompletion(scope: scope, generation: generation) else { return }
                lastError = "The original visit could not be saved and queued. Place lookup will wait."
                return
            }
            guard permitsCompletion(scope: scope, generation: generation) else { return }
            // A departure, refinement, or another visit can arrive while the
            // outbox write waits. Requeue changed raw facts before looking up.
            guard let current = store.visit(id: visit.visitID, now: now()),
                  Self.sameRawObservation(current, visit) else { continue }
            attempted.insert(visit.visitID)
            let attemptedAt = ObservationCoding.dateString(from: now())
            do {
                guard try store.applyPlaceContext(
                    VisitPlaceContext(
                        status: .pending, provider: resolver.provider, attemptedAt: attemptedAt
                    ),
                    to: visit.visitID, now: now()
                ) != nil else { continue }
            } catch {
                lastError = "The visit lookup state could not be saved."
                return
            }

            let context: VisitPlaceContext
            do {
                let result = try await Self.resolve(visit, using: resolver, timeout: timeout)
                let status: VisitPlaceContextStatus = result.status == .pending ? .unavailable : result.status
                context = VisitPlaceContext(
                    status: status,
                    provider: resolver.provider,
                    attemptedAt: attemptedAt,
                    resolvedAt: status == .resolved || status == .noMatch
                        ? ObservationCoding.dateString(from: now()) : nil,
                    address: result.address,
                    placeCandidates: result.placeCandidates,
                    attribution: result.attribution,
                    truncated: result.truncated,
                    failureReason: result.failureReason,
                    searchRadiusMeters: result.searchRadiusMeters,
                    partial: result.partial
                )
                lastError = status == .unavailable || result.partial
                    ? "Some place details were unavailable. The original visit is still shared." : nil
            } catch {
                guard permitsCompletion(scope: scope, generation: generation) else { return }
                // Network diagnostics can contain coordinates or credentials.
                lastError = "Place lookup was unavailable. The original visit is still shared."
                context = VisitPlaceContext(
                    status: .unavailable, provider: resolver.provider, attemptedAt: attemptedAt
                )
            }
            guard permitsCompletion(scope: scope, generation: generation) else { return }
            do {
                if let window = try store.applyPlaceContext(
                    context, to: visit.visitID, expectedVisit: visit, now: now()
                ) {
                    // Merge into the current entry; never re-record the stale pre-lookup snapshot.
                    publish(window)
                } else if let updated = store.visit(id: visit.visitID, now: now()),
                          updated.latitude != visit.latitude || updated.longitude != visit.longitude
                            || updated.horizontalAccuracyMeters != visit.horizontalAccuracyMeters {
                    // A refined fix arrived during lookup. Process its new input next.
                    attempted.remove(visit.visitID)
                }
            } catch {
                lastError = "Place details could not be saved. The original visit is still shared."
                return
            }
        }
    }

    private static func sameRawObservation(_ lhs: VisitSnapshot, _ rhs: VisitSnapshot) -> Bool {
        var left = lhs
        var right = rhs
        left.placeContext = nil
        right.placeContext = nil
        return left == right
    }

    private func permitsCompletion(scope: String, generation: UUID) -> Bool {
        !Task.isCancelled && self.generation == generation && self.scope == scope
            && currentScope() == scope
    }

    private func needsLookup(_ visit: VisitSnapshot, provider: String, at date: Date) -> Bool {
        guard let context = visit.placeContext else { return true }
        guard context.provider == provider else { return true }
        switch context.status {
        case .resolved, .noMatch:
            return false
        case .pending, .unavailable:
            guard let timestamp = context.attemptedAt,
                  let attempt = ObservationCoding.date(from: timestamp) else { return true }
            return date.timeIntervalSince(attempt) >= 300
        }
    }

    private static func resolve(
        _ visit: VisitSnapshot, using resolver: any VisitPlaceResolving, timeout: Duration
    ) async throws -> VisitPlaceContext {
        let race = VisitLookupRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                guard !Task.isCancelled else {
                    race.finish(.failure(CancellationError()))
                    return
                }
                race.lookup = Task { [weak race] in
                    do {
                        let result = try await resolver.resolve(visit)
                        race?.finish(.success(result))
                    } catch {
                        race?.finish(.failure(error))
                    }
                }
                race.deadline = Task { [weak race] in
                    do {
                        try await Task.sleep(for: timeout)
                        race?.finish(.failure(VisitEnrichmentError.timeout))
                    } catch {
                        // Finishing or cancelling the lookup cancels this deadline.
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}

/// A task group waits for a noncooperative resolver even after its deadline.
/// This race returns immediately and makes any late completion harmless.
@MainActor
private final class VisitLookupRace {
    var continuation: CheckedContinuation<VisitPlaceContext, any Error>?
    var lookup: Task<Void, Never>?
    var deadline: Task<Void, Never>?

    func finish(_ result: Result<VisitPlaceContext, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        lookup?.cancel()
        deadline?.cancel()
        lookup = nil
        deadline = nil
        continuation.resume(with: result)
    }
}

private enum VisitEnrichmentError: Error {
    case timeout
}
