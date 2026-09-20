import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit persistence acknowledgment")
@MainActor
struct VisitPersistenceAcknowledgmentTests {
    @Test("A blocked write is acknowledged only after its visit is on disk")
    func acknowledgmentFollowsPersistence() async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        try await fixture.configure()
        let window = fixture.window()
        var acknowledged = false
        let task = Task {
            try await fixture.publisher.persistVisits(window)
            acknowledged = true
        }
        try await waitUntil { fixture.writer.pending != nil }
        #expect(!acknowledged)
        #expect(try await fixture.outbox.pending(for: fixture.scope).isEmpty)

        fixture.writer.complete()
        try await task.value
        #expect(acknowledged)
        let restored = ObservationOutbox(fileURL: fixture.fileURL)
        let persisted = try #require(try await restored.pending(for: fixture.scope).first)
        #expect(persisted.kind == .visits)
        #expect(persisted.status == .available)
        let payload = try #require(persisted.payload?.value as? [String: Any])
        #expect((payload["visits"] as? [[String: Any]])?.count == 1)
        try await fixture.publisher.discardAllPending()
    }

    @Test("A failed queue write cannot be acknowledged")
    func failureIsPropagated() async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        try await fixture.configure()
        let task = Task { try await fixture.publisher.persistVisits(fixture.window()) }
        try await waitUntil { fixture.writer.pending != nil }
        fixture.writer.complete(throwing: VisitPersistenceTestError.failed)

        await #expect(throws: VisitPersistenceTestError.self) { try await task.value }
        #expect(try await fixture.outbox.pending(for: fixture.scope).isEmpty)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Caller cancellation and changed scopes reject a late write", arguments: [false, true])
    func cancellationRejectsAcknowledgment(changeScope: Bool) async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        try await fixture.configure()
        let task = Task { try await fixture.publisher.persistVisits(fixture.window()) }
        try await waitUntil { fixture.writer.pending != nil }
        // Even a writer that ignores cancellation cannot release the lookup gate.
        fixture.writer.reportSuccessWithoutWriting = true
        if changeScope {
            fixture.publisher.configure(
                baseURL: nil, token: nil, clientID: "", deliveryScope: nil,
                authorizationExpiresAt: nil
            )
        } else {
            task.cancel()
        }
        fixture.writer.complete()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.publisher.lastError == nil)
        #expect(try await fixture.outbox.pending(for: fixture.scope).isEmpty)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Forgetting waits for an acknowledged write to stop before deleting the queue")
    func teardownDrainsTrackedWrite() async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        try await fixture.configure()
        let task = Task { try await fixture.publisher.persistVisits(fixture.window()) }
        try await waitUntil { fixture.writer.pending != nil }
        var forgotten = false
        let forget = Task {
            try await fixture.publisher.discardAllPending()
            forgotten = true
        }
        try await waitUntil { fixture.uploader.didCancelAll }
        #expect(!forgotten)
        fixture.writer.complete()

        try await forget.value
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test("A stale visit ignored by coalescing cannot release the lookup gate")
    func ignoredWriteIsNotAcknowledged() async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        let future = Date().addingTimeInterval(3600)
        let newer = try ObservationEvent.available(
            kind: .visits, observedAt: future, payload: fixture.window(capturedAt: future)
        )
        #expect(try await fixture.outbox.enqueue(newer, for: fixture.scope))
        try await fixture.configure()
        let task = Task { try await fixture.publisher.persistVisits(fixture.window()) }
        try await waitUntil { fixture.writer.pending != nil }
        fixture.writer.complete()

        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try await fixture.outbox.pending(for: fixture.scope).first?.eventID == newer.eventID)
        try await fixture.publisher.discardAllPending()
    }

    @Test("A privacy withdrawal is durable but cannot authorize a place lookup")
    func withdrawalIsNotAvailableAcknowledgment() async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        fixture.publisher.visitDisclosure = { .withdrawn }
        try await fixture.configure()
        let task = Task { try await fixture.publisher.persistVisits(fixture.window()) }
        try await waitUntil { fixture.writer.pending != nil }
        fixture.writer.complete()

        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try await fixture.outbox.pending(for: fixture.scope).first?.status == .withdrawn)
        try await fixture.publisher.discardAllPending()
    }

    @Test("A publisher without a recipient cannot acknowledge visit persistence")
    func missingScopeDoesNotWrite() async throws {
        let fixture = VisitPersistenceFixture()
        defer { fixture.cleanup() }
        await #expect(throws: ObservationOutboxError.self) {
            try await fixture.publisher.persistVisits(fixture.window())
        }
        #expect(fixture.writer.pending == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VisitPersistenceTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct VisitPersistenceFixture {
    let fileURL: URL
    let outbox: ObservationOutbox
    let writer: DeferredVisitWriter
    let uploader: PersistenceUnusedUploader
    let publisher: ObservationPublisher
    let scope = ObservationDeliveryScope(connectionID: "visit-persistence", identityID: "test-identity")

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("visit-persistence-\(UUID().uuidString)")
            .appendingPathComponent("outbox.json")
        outbox = ObservationOutbox(fileURL: fileURL)
        writer = DeferredVisitWriter(outbox: outbox)
        uploader = PersistenceUnusedUploader()
        let writer = writer
        publisher = ObservationPublisher(outbox: outbox, uploader: uploader) { event, scope in
            try await writer.enqueue(event, for: scope)
        }
    }

    func configure() async throws {
        try await outbox.bind(to: scope)
        publisher.configure(
            baseURL: nil, token: nil, clientID: "", deliveryScope: scope,
            authorizationExpiresAt: nil
        )
    }

    func window(capturedAt: Date = Date()) -> VisitWindowSnapshot {
        let timestamp = ObservationCoding.dateString(from: capturedAt)
        let visit = VisitSnapshot(
            latitude: 40, longitude: -105, horizontalAccuracyMeters: 20,
            arrival: .unknown, arrivedAt: nil, departedAt: nil, state: .ongoing,
            dwellSeconds: nil, dwellIsPartial: true, capturedAt: timestamp
        )
        return VisitWindowSnapshot(
            capturedAt: timestamp, windowHours: 48, maxEntries: 16,
            returnedCount: 1, truncated: false, visits: [visit]
        )
    }

    func cleanup() {
        writer.complete(throwing: CancellationError())
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

@MainActor
private final class DeferredVisitWriter {
    let outbox: ObservationOutbox
    var pending: CheckedContinuation<Void, any Error>?
    var reportSuccessWithoutWriting = false

    init(outbox: ObservationOutbox) { self.outbox = outbox }

    func enqueue(_ event: ObservationEvent, for scope: ObservationDeliveryScope) async throws -> Bool {
        try await withCheckedThrowingContinuation { pending = $0 }
        if reportSuccessWithoutWriting { return true }
        return try await outbox.enqueue(event, for: scope)
    }

    func complete(throwing error: (any Error)? = nil) {
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
        pending = nil
    }
}

@MainActor
private final class PersistenceUnusedUploader: ObservationUploading {
    var didCancelAll = false

    func upload(_ batch: ObservationBatch, to baseURL: URL, token: String) async throws -> ObservationIngestResult {
        Issue.record("An unconfigured publisher must not upload")
        throw CancellationError()
    }

    func cancelAllTransfers() async { didCancelAll = true }

    func cancelTransfers(disallowedBy disclosure: VisitObservationDisclosure) async {}
}

private enum VisitPersistenceTestError: Error {
    case failed
    case timeout
}
