import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit enrichment coordination")
@MainActor
struct VisitEnrichmentCoordinatorTests {
    @Test("A delayed lookup preserves a newer departure")
    func departureWhileResolving() async throws {
        let fixture = try EnrichmentFixture()
        defer { fixture.cleanUp() }
        let arrival = fixture.date.addingTimeInterval(-600)
        let original = try fixture.record(arrival: arrival, departure: .distantFuture)
        let resolver = DeferredVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.pending != nil }
        _ = try fixture.record(arrival: arrival, departure: fixture.date)
        resolver.complete()
        try await waitUntil { !fixture.coordinator.isResolving }

        let updated = try #require(fixture.store.visit(id: original.visitID, now: fixture.date))
        #expect(updated.state == .settled)
        #expect(updated.departedAt != nil)
        #expect(updated.placeContext?.status == .resolved)
        #expect(fixture.publications.last?.visits.count == 1)
    }

    @Test("A withdrawn lookup cannot return after consent is re-enabled")
    func revokedGenerationCannotPublish() async throws {
        let fixture = try EnrichmentFixture()
        defer { fixture.cleanUp() }
        let visit = try fixture.record()
        let oldResolver = DeferredVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: oldResolver)
        try await waitUntil { oldResolver.pending != nil }
        fixture.scope = nil
        fixture.coordinator.invalidate()
        _ = try fixture.store.removePlaceContext(now: fixture.date)
        fixture.scope = "first"
        let newResolver = ImmediateVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: newResolver)
        try await waitUntil { newResolver.calls == 1 && !fixture.coordinator.isResolving }
        let publications = fixture.publications.count
        oldResolver.complete()
        await Task.yield()
        await Task.yield()
        #expect(fixture.publications.count == publications)
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext?.provider == "new")
    }

    @Test("Changing the current sharing scope rejects a completion")
    func scopeChangesWithoutCancellation() async throws {
        let fixture = try EnrichmentFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.record()
        let resolver = DeferredVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.pending != nil }
        fixture.scope = "replacement"
        resolver.complete()
        try await waitUntil { !fixture.coordinator.isResolving }
        #expect(fixture.publications.isEmpty)
    }

    @Test("Timeout retains the original visit and defers retries")
    func timeoutAndRetryCooldown() async throws {
        let fixture = try EnrichmentFixture(timeout: .milliseconds(1))
        defer { fixture.cleanUp() }
        let visit = try fixture.record()
        let resolver = SlowVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.calls == 1 && !fixture.coordinator.isResolving }
        let updated = try #require(fixture.store.visit(id: visit.visitID, now: fixture.date))
        #expect(updated.capturedAt == visit.capturedAt)
        #expect(updated.arrivedAt == visit.arrivedAt)
        #expect(updated.placeContext?.status == .unavailable)
        #expect(fixture.publications.count == 1)
        fixture.coordinator.resume()
        await Task.yield()
        #expect(resolver.calls == 1)
        fixture.date = fixture.date.addingTimeInterval(301)
        fixture.coordinator.resume()
        try await waitUntil { resolver.calls == 2 && !fixture.coordinator.isResolving }
    }

    @Test("An expired visit cannot be recreated by a lookup")
    func expirationWhileResolving() async throws {
        let fixture = try EnrichmentFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.record()
        let resolver = DeferredVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.pending != nil }
        fixture.date = fixture.date.addingTimeInterval(49 * 3600)
        resolver.complete()
        try await waitUntil { !fixture.coordinator.isResolving }
        #expect(fixture.store.window(now: fixture.date).visits.isEmpty)
        #expect(fixture.publications.isEmpty)
    }

    @Test("Timeout returns even when a resolver ignores cancellation")
    func uncooperativeTimeout() async throws {
        let fixture = try EnrichmentFixture(timeout: .milliseconds(10))
        defer { fixture.cleanUp() }
        let visit = try fixture.record()
        let resolver = DeferredVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.pending != nil }
        try await waitUntil { !fixture.coordinator.isResolving }
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext?.status == .unavailable)
        let publications = fixture.publications.count
        resolver.complete()
        await Task.yield()
        await Task.yield()
        #expect(fixture.publications.count == publications)
    }

    @Test("The coordinator stamps failures and does not trust adapter retry metadata")
    func failureWithoutTimestamp() async throws {
        let fixture = try EnrichmentFixture()
        defer { fixture.cleanUp() }
        let visit = try fixture.record()
        let resolver = ImmediateVisitResolver(status: .unavailable)
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.calls == 1 && !fixture.coordinator.isResolving }
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext?.attemptedAt != nil)
        fixture.coordinator.resume()
        await Task.yield()
        await Task.yield()
        #expect(resolver.calls == 1)
    }

    @Test("A provider change refreshes resolved context")
    func providerChange() async throws {
        let fixture = try EnrichmentFixture()
        defer { fixture.cleanUp() }
        let visit = try fixture.record()
        _ = try fixture.store.applyPlaceContext(
            VisitPlaceContext(status: .resolved, provider: "old"),
            to: visit.visitID, now: fixture.date
        )
        let resolver = ImmediateVisitResolver()
        fixture.coordinator.configure(scope: "first", resolver: resolver)
        try await waitUntil { resolver.calls == 1 && !fixture.coordinator.isResolving }
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext?.provider == "new")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for visit enrichment")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class EnrichmentFixture {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: VisitWindowStore
    var scope: String? = "first"
    var date = Date()
    var publications: [VisitWindowSnapshot] = []
    var coordinator: VisitEnrichmentCoordinator!

    init(timeout: Duration = .seconds(2)) throws {
        store = VisitWindowStore(fileURL: fileURL)
        coordinator = VisitEnrichmentCoordinator(
            store: store,
            currentScope: { [weak self] in self?.scope },
            publish: { [weak self] in self?.publications.append($0) },
            now: { [weak self] in self?.date ?? Date() },
            timeout: timeout
        )
    }

    func record(arrival: Date? = nil, departure: Date? = nil) throws -> VisitSnapshot {
        let value = try #require(VisitSnapshot.make(
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -105),
            horizontalAccuracy: 15,
            arrivalDate: arrival ?? date.addingTimeInterval(-600),
            departureDate: departure ?? date,
            capturedAt: date
        ))
        return try #require(store.record(value, now: date).visits.first)
    }

    func cleanUp() {
        coordinator.invalidate()
        store.discardAll()
    }
}

@MainActor
private final class DeferredVisitResolver: VisitPlaceResolving {
    let provider = "old"
    var pending: CheckedContinuation<VisitPlaceContext, any Error>?

    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete() {
        pending?.resume(returning: VisitPlaceContext(status: .resolved, provider: provider))
        pending = nil
    }
}

@MainActor
private final class ImmediateVisitResolver: VisitPlaceResolving {
    let provider = "new"
    var calls = 0
    let status: VisitPlaceContextStatus
    init(status: VisitPlaceContextStatus = .resolved) { self.status = status }
    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        calls += 1
        return VisitPlaceContext(status: status, provider: provider)
    }
}

@MainActor
private final class SlowVisitResolver: VisitPlaceResolving {
    let provider = "slow"
    var calls = 0
    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        calls += 1
        try await Task.sleep(for: .seconds(5))
        return VisitPlaceContext(status: .resolved, provider: provider)
    }
}
