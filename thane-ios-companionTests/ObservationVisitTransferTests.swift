import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Observation visit transfer policy")
struct ObservationVisitTransferTests {
    @Test("Task markers describe the most private available visit body")
    func classifiesAvailableVisits() {
        let raw = event(kind: .visits, payload: ["visits": [["latitude": 40.0]]])
        let enriched = event(kind: .visits, payload: [
            "visits": [["place_context": ["provider": "apple_maps"]]]
        ])
        let location = event(kind: .location, payload: ["latitude": 40.0])
        let cases: [([ObservationEvent], ObservationVisitTransferContent)] = [
            ([], .none),
            ([location, .withdrawn(kind: .visits)], .none),
            ([raw, location], .raw),
            ([enriched, location], .enriched),
            ([enriched, raw], .enriched),
            ([event(kind: .visits, payload: [:])], .enriched)
        ]
        for (events, expected) in cases {
            #expect(ObservationVisitTransferContent(batch: batch(events)) == expected)
        }
    }

    @Test("Revocation only rejects tasks exceeding current visit disclosure")
    func policyMatrix() {
        let cases: [(String?, Bool, Bool)] = [
            (ObservationVisitTransferContent.none.rawValue, false, false),
            (ObservationVisitTransferContent.raw.rawValue, false, true),
            (ObservationVisitTransferContent.enriched.rawValue, true, true),
            (nil, true, true),
            ("unknown-version", true, true)
        ]
        for (marker, cancelWhenRaw, cancelWhenWithdrawn) in cases {
            #expect(!ObservationVisitTransferContent.shouldCancel(taskDescription: marker, disallowedBy: .enriched))
            #expect(ObservationVisitTransferContent.shouldCancel(
                taskDescription: marker, disallowedBy: .raw
            ) == cancelWhenRaw)
            #expect(ObservationVisitTransferContent.shouldCancel(
                taskDescription: marker, disallowedBy: .withdrawn
            ) == cancelWhenWithdrawn)
        }
    }

    @Test("Selective cancellation leaves ordinary and permitted raw tasks untouched")
    func preservesPermittedTasks() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://thane.example/never-started"))
        let ordinary = session.dataTask(with: url)
        ordinary.taskDescription = ObservationVisitTransferContent.none.rawValue
        let raw = session.dataTask(with: url)
        raw.taskDescription = ObservationVisitTransferContent.raw.rawValue
        let enriched = session.dataTask(with: url)
        enriched.taskDescription = ObservationVisitTransferContent.enriched.rawValue
        let legacy = session.dataTask(with: url)

        ObservationBackgroundSession.cancelTransfers(
            in: [ordinary, raw, enriched, legacy], disallowedBy: .raw
        )
        #expect(ordinary.state == .suspended)
        #expect(raw.state == .suspended)
        #expect(enriched.state == .canceling || enriched.state == .completed)
        #expect(legacy.state == .canceling || legacy.state == .completed)

        ObservationBackgroundSession.cancelTransfers(in: [ordinary, raw], disallowedBy: .withdrawn)
        #expect(ordinary.state == .suspended)
        #expect(raw.state == .canceling || raw.state == .completed)
    }

    private func event(kind: ObservationKind, payload: [String: Any]) -> ObservationEvent {
        ObservationEvent(
            eventID: UUID(), kind: kind, schemaVersion: 1, status: .available,
            observedAt: Date(), payload: AnyCodable(payload)
        )
    }

    private func batch(_ events: [ObservationEvent]) -> ObservationBatch {
        ObservationBatch(
            clientID: "test-client", clientName: "Test", platform: "ios",
            appVersion: "test", osVersion: "test", events: events
        )
    }
}
