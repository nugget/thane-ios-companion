import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit lookup durability")
@MainActor
struct VisitLookupDurabilityTests {
    @Test("A failed visit checkpoint blocks lookup until persistence recovers")
    func failedStoreRetriesBeforeLookup() async throws {
        let fixture = try LookupDurabilityFixture(blockStore: true)
        defer { fixture.cleanup() }
        let visit = try fixture.makeVisit()
        #expect(throws: (any Error).self) {
            try fixture.store.record(visit, now: fixture.date)
        }
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date) == visit)

        fixture.start()
        try await waitUntil { fixture.coordinator.lastError != nil && !fixture.coordinator.isResolving }
        #expect(fixture.gate.windows.isEmpty)
        #expect(fixture.resolver.visits.isEmpty)
        #expect(fixture.publications.isEmpty)

        try FileManager.default.removeItem(at: fixture.storageDirectory)
        fixture.coordinator.resume()
        try await waitUntil { fixture.gate.windows.count == 1 }
        let restored = VisitWindowStore(fileURL: fixture.fileURL)
        #expect(restored.visit(id: visit.visitID, now: fixture.date) == visit)
        #expect(fixture.resolver.visits.isEmpty)
        fixture.gate.succeed(0)
        try await waitUntil { fixture.resolver.visits.count == 1 }
        fixture.resolver.succeed(0)
        try await waitUntil { fixture.publications.count == 1 && !fixture.coordinator.isResolving }
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext?.status == .resolved)
    }

    @Test("A blocked or failed outbox gate never starts the resolver")
    func failedGateRetriesBeforeLookup() async throws {
        let fixture = try LookupDurabilityFixture()
        defer { fixture.cleanup() }
        let visit = try fixture.makeVisit()
        try fixture.store.record(visit, now: fixture.date)
        fixture.start()
        try await waitUntil { fixture.gate.windows.count == 1 }
        #expect(fixture.resolver.visits.isEmpty)
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext == nil)

        fixture.gate.fail(0)
        try await waitUntil { fixture.coordinator.lastError != nil && !fixture.coordinator.isResolving }
        #expect(fixture.resolver.visits.isEmpty)
        #expect(fixture.publications.isEmpty)
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext == nil)

        fixture.coordinator.resume()
        try await waitUntil { fixture.gate.windows.count == 2 }
        fixture.gate.succeed(1)
        try await waitUntil { fixture.resolver.visits.count == 1 }
        #expect(fixture.resolver.visits[0].visitID == visit.visitID)
        fixture.resolver.succeed(0)
        try await waitUntil { fixture.publications.count == 1 && !fixture.coordinator.isResolving }
    }

    @Test("Changed raw facts are queued again before lookup", arguments: ["departure", "coordinate"])
    func rawRevisionDuringGate(change: String) async throws {
        let fixture = try LookupDurabilityFixture()
        defer { fixture.cleanup() }
        let arrival = fixture.date.addingTimeInterval(-600)
        let original = try fixture.makeVisit(arrival: arrival, ongoing: true)
        try fixture.store.record(original, now: fixture.date)
        fixture.start()
        try await waitUntil { fixture.gate.windows.count == 1 }

        fixture.date = fixture.date.addingTimeInterval(1)
        let update = try fixture.makeVisit(
            arrival: arrival, ongoing: change != "departure",
            latitude: change == "coordinate" ? 41 : 40
        )
        try fixture.store.record(update, now: fixture.date)
        let revised = try #require(fixture.store.visit(id: original.visitID, now: fixture.date))
        fixture.gate.succeed(0)
        try await waitUntil { fixture.gate.windows.count == 2 }
        #expect(fixture.resolver.visits.isEmpty)
        #expect(fixture.gate.windows[1].visits == [revised])
        #expect(revised.placeContext == nil)

        fixture.gate.succeed(1)
        try await waitUntil { fixture.resolver.visits.count == 1 }
        #expect(fixture.resolver.visits[0] == revised)
        fixture.resolver.succeed(0)
        try await waitUntil { fixture.publications.count == 1 && !fixture.coordinator.isResolving }
        let published = try #require(fixture.publications.last?.visits.first)
        #expect(published.capturedAt == revised.capturedAt)
        #expect(published.departedAt == revised.departedAt)
        #expect(published.latitude == revised.latitude)
    }

    @Test("A visit arriving during another lookup has its own durability gate")
    func nextVisitInActiveWorkerIsGated() async throws {
        let fixture = try LookupDurabilityFixture()
        defer { fixture.cleanup() }
        let first = try fixture.makeVisit()
        try fixture.store.record(first, now: fixture.date)
        fixture.start()
        try await waitUntil { fixture.gate.windows.count == 1 }
        fixture.gate.succeed(0)
        try await waitUntil { fixture.resolver.visits.count == 1 }

        fixture.date = fixture.date.addingTimeInterval(1)
        let second = try fixture.makeVisit(arrival: fixture.date.addingTimeInterval(-100), latitude: 41)
        try fixture.store.record(second, now: fixture.date)
        fixture.coordinator.resume()
        fixture.resolver.succeed(0)
        try await waitUntil { fixture.gate.windows.count == 2 }
        #expect(fixture.resolver.visits.count == 1)
        #expect(fixture.gate.windows[1].visits.contains { $0.visitID == second.visitID && $0.placeContext == nil })
        fixture.gate.fail(1)
        try await waitUntil { fixture.coordinator.lastError != nil && !fixture.coordinator.isResolving }
        #expect(fixture.resolver.visits.count == 1)
        #expect(fixture.publications.count == 1)
        #expect(fixture.store.visit(id: first.visitID, now: fixture.date)?.placeContext?.status == .resolved)
        #expect(fixture.store.visit(id: second.visitID, now: fixture.date)?.placeContext == nil)

        fixture.coordinator.resume()
        try await waitUntil { fixture.gate.windows.count == 3 }
        fixture.gate.succeed(2)
        try await waitUntil { fixture.resolver.visits.count == 2 }
        #expect(fixture.resolver.visits[1].visitID == second.visitID)
        fixture.resolver.succeed(1)
        try await waitUntil { fixture.publications.count == 2 && !fixture.coordinator.isResolving }
    }

    @Test("Re-enabling consent cannot authorize an earlier suspended gate")
    func staleGateAfterReenable() async throws {
        let fixture = try LookupDurabilityFixture()
        let replacement = DurabilityVisitResolver(provider: "replacement")
        defer {
            fixture.cleanup()
            replacement.cancelAll()
        }
        let visit = try fixture.makeVisit()
        try fixture.store.record(visit, now: fixture.date)
        fixture.start()
        try await waitUntil { fixture.gate.windows.count == 1 }

        fixture.scope = nil
        fixture.coordinator.invalidate()
        fixture.scope = "first"
        fixture.coordinator.configure(scope: "first", resolver: replacement)
        try await waitUntil { fixture.gate.windows.count == 2 }
        fixture.gate.succeed(0)
        try await waitUntil { fixture.gate.returned.contains(0) }
        #expect(fixture.resolver.visits.isEmpty)
        #expect(replacement.visits.isEmpty)
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext == nil)
        #expect(fixture.publications.isEmpty)

        fixture.gate.succeed(1)
        try await waitUntil { replacement.visits.count == 1 }
        replacement.succeed(0)
        try await waitUntil { fixture.publications.count == 1 && !fixture.coordinator.isResolving }
        #expect(fixture.resolver.visits.isEmpty)
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext?.provider == "replacement")
    }

    @Test("Changing scope during persistence prevents lookup even without explicit invalidation")
    func scopeChangeDuringGate() async throws {
        let fixture = try LookupDurabilityFixture()
        defer { fixture.cleanup() }
        let visit = try fixture.makeVisit()
        try fixture.store.record(visit, now: fixture.date)
        fixture.start()
        try await waitUntil { fixture.gate.windows.count == 1 }
        fixture.scope = "other"
        fixture.gate.succeed(0)
        try await waitUntil { fixture.gate.returned.contains(0) && !fixture.coordinator.isResolving }
        #expect(fixture.resolver.visits.isEmpty)
        #expect(fixture.publications.isEmpty)
        #expect(fixture.store.visit(id: visit.visitID, now: fixture.date)?.placeContext == nil)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the controlled durability transition")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class LookupDurabilityFixture {
    let directory: URL
    let storageDirectory: URL
    let fileURL: URL
    let store: VisitWindowStore
    let gate = DeferredDurabilityGate()
    let resolver = DurabilityVisitResolver()
    var scope: String? = "first"
    var date = Date()
    var publications: [VisitWindowSnapshot] = []
    var coordinator: VisitEnrichmentCoordinator!

    init(blockStore: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storageDirectory = directory.appendingPathComponent("storage")
        fileURL = storageDirectory.appendingPathComponent("visits.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if blockStore {
            try Data("not a directory".utf8).write(to: storageDirectory)
        }
        store = VisitWindowStore(fileURL: fileURL)
        coordinator = VisitEnrichmentCoordinator(
            store: store,
            currentScope: { [weak self] in self?.scope },
            prepareLookup: { [weak self] window in
                guard let self else { throw CancellationError() }
                try await gate.prepare(window)
            },
            publish: { [weak self] in self?.publications.append($0) },
            now: { [weak self] in self?.date ?? Date() },
            timeout: .seconds(60)
        )
    }

    func start() {
        coordinator.configure(scope: "first", resolver: resolver)
    }

    func makeVisit(arrival: Date? = nil, ongoing: Bool = false, latitude: Double = 40) throws -> VisitSnapshot {
        try #require(VisitSnapshot.make(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -105),
            horizontalAccuracy: 15,
            arrivalDate: arrival ?? date.addingTimeInterval(-600),
            departureDate: ongoing ? .distantFuture : date,
            capturedAt: date
        ))
    }

    func cleanup() {
        scope = nil
        coordinator.invalidate()
        gate.cancelAll()
        resolver.cancelAll()
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the visit durability fixture: \(error)")
        }
    }
}

@MainActor
private final class DeferredDurabilityGate {
    var windows: [VisitWindowSnapshot] = []
    var returned: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]

    func prepare(_ window: VisitWindowSnapshot) async throws {
        let index = windows.count
        windows.append(window)
        defer { returned.insert(index) }
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func succeed(_ index: Int) {
        pending.removeValue(forKey: index)?.resume()
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: DurabilityTestError.writeFailed)
    }

    func cancelAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
private final class DurabilityVisitResolver: VisitPlaceResolving {
    let provider: String
    var visits: [VisitSnapshot] = []
    private var pending: [Int: CheckedContinuation<VisitPlaceContext, any Error>] = [:]

    init(provider: String = "durability-test") {
        self.provider = provider
    }

    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        let index = visits.count
        visits.append(visit)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func succeed(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(returning: VisitPlaceContext(status: .resolved, provider: provider))
    }

    func cancelAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private enum DurabilityTestError: Error {
    case writeFailed
}
