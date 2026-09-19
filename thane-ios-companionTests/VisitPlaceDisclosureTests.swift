import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit place delivery disclosure")
@MainActor
struct VisitPlaceDisclosureTests {
    @Test("Restored private context is replaced durably before delivery by default")
    func restoredContextDefaultsToRaw() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        let original = fixture.enrichedEvent()
        try await fixture.outbox.enqueue(original, for: fixture.scope)
        fixture.configure()
        try await waitUntil { fixture.uploader.batches.count == 1 && !fixture.publisher.isUploading }

        let sent = try #require(fixture.uploader.batches.first?.events.first)
        #expect(sent.eventID != original.eventID)
        #expect(sent.observedAt > original.observedAt)
        #expect(sent.status == .available)
        let payload = try #require(sent.payload?.value as? [String: Any])
        let visit = try #require((payload["visits"] as? [[String: Any]])?.first)
        #expect(visit["place_context"] == nil)
        #expect(visit["latitude"] as? Double == 40)
        #expect(payload["captured_at"] as? String == ObservationCoding.dateString(from: sent.observedAt))
        let restored = try await ObservationOutbox(fileURL: fixture.fileURL).pending(for: fixture.scope)
        #expect(restored.first?.eventID == sent.eventID)
        #expect(fixture.uploader.cancellationCount == 1)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Disabled parent sharing sends a withdrawal for a restored window")
    func disabledParentsWithdraw() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        let original = fixture.enrichedEvent()
        try await fixture.outbox.enqueue(original, for: fixture.scope)
        fixture.publisher.visitDisclosure = { .withdrawn }
        fixture.configure()
        try await waitUntil { fixture.uploader.batches.count == 1 && !fixture.publisher.isUploading }

        let sent = try #require(fixture.uploader.batches.first?.events.first)
        #expect(sent.status == .withdrawn)
        #expect(sent.payload == nil)
        #expect(sent.eventID != original.eventID)
        #expect(sent.observedAt > original.observedAt)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Consent preserves context and event identity")
    func permittedContextIsUnchanged() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        let original = fixture.enrichedEvent()
        try await fixture.outbox.enqueue(original, for: fixture.scope)
        fixture.publisher.visitDisclosure = { .enriched }
        fixture.configure()
        try await waitUntil { fixture.uploader.batches.count == 1 && !fixture.publisher.isUploading }

        #expect(fixture.uploader.batches.first?.events.first?.eventID == original.eventID)
        #expect(fixture.uploader.cancellationCount == 0)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Revocation cancels a pending private transfer and replaces its body")
    func revocationReplacesInFlightContext() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        fixture.uploader.holdFirstUpload = true
        fixture.publisher.visitDisclosure = { .enriched }
        let original = fixture.enrichedEvent()
        try await fixture.outbox.enqueue(original, for: fixture.scope)
        fixture.configure()
        try await waitUntil { fixture.uploader.batches.count == 1 }

        fixture.publisher.visitDisclosure = { .raw }
        fixture.publisher.reconcileVisitDisclosure()
        try await waitUntil { fixture.uploader.batches.count == 2 && !fixture.publisher.isUploading }

        let replacement = try #require(fixture.uploader.batches.last?.events.first)
        let payload = try #require(replacement.payload?.value as? [String: Any])
        let visit = try #require((payload["visits"] as? [[String: Any]])?.first)
        #expect(visit["place_context"] == nil)
        #expect(replacement.eventID != original.eventID)
        #expect(replacement.observedAt > original.observedAt)
        #expect(fixture.uploader.cancellationCount == 1)
        try await fixture.publisher.discardAllPending()
    }

    @Test("The final boundary sanitizes a stale window queued after preparation")
    func staleLateEventIsSanitized() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        try await fixture.outbox.enqueue(.withdrawn(kind: .visits), for: fixture.scope)
        fixture.configure()
        try await waitUntil { fixture.uploader.batches.count == 1 && !fixture.publisher.isUploading }
        let original = fixture.enrichedEvent(observedAt: Date().addingTimeInterval(1))
        try await fixture.outbox.enqueue(original, for: fixture.scope)
        fixture.publisher.flush()
        try await waitUntil { fixture.uploader.batches.count == 2 && !fixture.publisher.isUploading }

        let sent = try #require(fixture.uploader.batches.last?.events.first)
        let payload = try #require(sent.payload?.value as? [String: Any])
        let visit = try #require((payload["visits"] as? [[String: Any]])?.first)
        #expect(visit["place_context"] == nil)
        #expect(sent.eventID != original.eventID)
        #expect(sent.observedAt > original.observedAt)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Changing visit consent preserves an ordinary in-flight upload")
    func ordinaryTransferSurvivesVisitRevocation() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        fixture.uploader.holdFirstUpload = true
        fixture.publisher.visitDisclosure = { .enriched }
        let event = ObservationEvent(
            eventID: UUID(), kind: .location, schemaVersion: 1, status: .available,
            observedAt: Date(), payload: AnyCodable(["latitude": 40.0])
        )
        try await fixture.outbox.enqueue(event, for: fixture.scope)
        fixture.configure()
        try await waitUntil { fixture.uploader.batches.count == 1 }

        fixture.publisher.visitDisclosure = { .withdrawn }
        fixture.publisher.reconcileVisitDisclosure()
        try await waitUntil { fixture.uploader.cancellationCount == 1 }
        #expect(fixture.publisher.isUploading)
        #expect(fixture.uploader.batches.count == 1)
        fixture.uploader.completeSuspendedUpload()
        try await waitUntil { fixture.publisher.pendingCount == 0 && !fixture.publisher.isUploading }
        #expect(fixture.uploader.batches.count == 1)
        #expect(try await fixture.outbox.pending(for: fixture.scope).isEmpty)
        try await fixture.publisher.discardAllPending()
    }

    @Test("Sanitizing an old snapshot cannot overwrite a newer queued window")
    func replacementChecksCurrentEventIdentity() async throws {
        let fixture = DisclosureFixture()
        defer { fixture.cleanup() }
        let old = fixture.enrichedEvent()
        let newer = fixture.enrichedEvent(observedAt: old.observedAt.addingTimeInterval(1))
        try await fixture.outbox.enqueue(newer, for: fixture.scope)
        let replacement = ObservationEvent.withdrawn(
            kind: .visits, observedAt: newer.observedAt.addingTimeInterval(1)
        )
        let changed = try await fixture.outbox.replacePending(
            replacement, replacing: old.eventID, for: fixture.scope
        )
        #expect(!changed)
        #expect(try await fixture.outbox.pending(for: fixture.scope).first?.eventID == newer.eventID)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw DisclosureTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct DisclosureFixture {
    let fileURL: URL
    let outbox: ObservationOutbox
    let uploader: DisclosureUploader
    let publisher: ObservationPublisher
    let scope = ObservationDeliveryScope(connectionID: "disclosure-test", identityID: "test-identity")

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("visit-disclosure-\(UUID().uuidString)")
            .appendingPathComponent("outbox.json")
        outbox = ObservationOutbox(fileURL: fileURL)
        uploader = DisclosureUploader()
        publisher = ObservationPublisher(outbox: outbox, uploader: uploader)
    }

    func configure() {
        publisher.configure(
            baseURL: URL(string: "https://thane.example"), token: "test-token", clientID: "test-client",
            deliveryScope: scope, authorizationExpiresAt: .distantFuture
        )
    }

    func enrichedEvent(observedAt: Date = Date().addingTimeInterval(-60)) -> ObservationEvent {
        ObservationEvent(
            eventID: UUID(), kind: .visits, schemaVersion: 1, status: .available,
            observedAt: observedAt,
            payload: AnyCodable([
                "captured_at": ObservationCoding.dateString(from: observedAt),
                "visits": [[
                    "latitude": 40.0, "longitude": -105.0,
                    "place_context": ["provider": "apple_maps", "address": ["formatted": "Test address"]]
                ]]
            ])
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

@MainActor
private final class DisclosureUploader: ObservationUploading {
    var batches: [ObservationBatch] = []
    var cancellationCount = 0
    var holdFirstUpload = false
    private var suspendedUpload: CheckedContinuation<ObservationIngestResult, any Error>?

    func upload(_ batch: ObservationBatch, to baseURL: URL, token: String) async throws -> ObservationIngestResult {
        batches.append(batch)
        if holdFirstUpload, batches.count == 1 {
            return try await withCheckedThrowingContinuation { suspendedUpload = $0 }
        }
        // Keep the durable body for verification, as after a lost acknowledgement.
        throw DisclosureTestError.deliveryFailed
    }

    func cancelAllTransfers() async {
        cancellationCount += 1
        suspendedUpload?.resume(throwing: CancellationError())
        suspendedUpload = nil
    }

    func cancelTransfers(disallowedBy disclosure: VisitObservationDisclosure) async {
        cancellationCount += 1
        guard let batch = batches.last,
              ObservationVisitTransferContent.shouldCancel(
                taskDescription: ObservationVisitTransferContent(batch: batch).rawValue,
                disallowedBy: disclosure
              ) else { return }
        suspendedUpload?.resume(throwing: CancellationError())
        suspendedUpload = nil
    }

    func completeSuspendedUpload() {
        suspendedUpload?.resume(returning: ObservationIngestResult(stored: 1, ignored: 0, receivedAt: Date()))
        suspendedUpload = nil
    }
}

private enum DisclosureTestError: Error {
    case timeout
    case deliveryFailed
}
