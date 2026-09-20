import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit publication ordering")
@MainActor
struct VisitPublicationTests {
    @Test("Enrichment and withdrawal replace visits published in the same millisecond")
    func ordering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = ObservationOutbox(fileURL: directory.appendingPathComponent("outbox.json"))
        let publisher = ObservationPublisher(outbox: outbox, uploader: UnusedVisitUploader())
        let scope = ObservationDeliveryScope(connectionID: "profile", identityID: "identity")
        _ = try await outbox.bind(to: scope)
        publisher.configure(
            baseURL: nil, token: nil, clientID: "", deliveryScope: scope,
            authorizationExpiresAt: nil
        )
        let timestamp = ObservationCoding.dateString(from: Date())
        for count in 0..<10 {
            publisher.publishVisits(VisitWindowSnapshot(
                capturedAt: timestamp, windowHours: 48, maxEntries: 16,
                returnedCount: count, truncated: false, visits: []
            ))
        }
        var available: ObservationEvent?
        for _ in 0..<100 {
            available = try await outbox.pending(for: scope).first
            if let event = available,
               let payload = event.payload,
               let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
                    as? [String: Any],
               object["returned_count"] as? Int == 9 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let published = try #require(available)
        let payload = try #require(published.payload)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        #expect(object["returned_count"] as? Int == 9)
        #expect(object["captured_at"] as? String == ObservationCoding.dateString(from: published.observedAt))
        publisher.withdraw(.visits)
        var withdrawn: ObservationEvent?
        for _ in 0..<100 {
            withdrawn = try await outbox.pending(for: scope).first
            if withdrawn?.status == .withdrawn { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let last = try #require(withdrawn)
        #expect(last.status == .withdrawn)
        #expect(last.observedAt > published.observedAt)
        try await publisher.discardAllPending()
    }
}

@MainActor
private struct UnusedVisitUploader: ObservationUploading {
    func upload(
        _ batch: ObservationBatch, to baseURL: URL, token: String
    ) async throws -> ObservationIngestResult {
        Issue.record("Unconfigured publisher must not upload")
        throw CancellationError()
    }
}
