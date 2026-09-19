import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit place context")
@MainActor
struct VisitPlaceContextTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Legacy windows decode without context and retain stable identities across reloads")
    func legacyWindowIdentityIsStable() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let original = try makeVisit(capturedAt: now)
        let data = try ObservationCoding.encoder().encode(original)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "visit_id")
        legacy.removeValue(forKey: "place_context")
        try JSONSerialization.data(withJSONObject: ["visits": [legacy]])
            .write(to: fixture.fileURL)

        let first = try #require(VisitWindowStore(fileURL: fixture.fileURL).window(now: now).visits.first)
        let second = try #require(VisitWindowStore(fileURL: fixture.fileURL).window(now: now).visits.first)
        #expect(first.visitID == second.visitID)
        #expect(first.placeContext == nil)
        #expect(first.capturedAt == original.capturedAt)
        #expect(first.arrivedAt == original.arrivedAt)
        #expect(first.departedAt == original.departedAt)

        let store = VisitWindowStore(fileURL: fixture.fileURL)
        try store.applyPlaceContext(resolvedContext(), to: first.visitID, now: now)
        let restored = try #require(VisitWindowStore(fileURL: fixture.fileURL).visit(id: first.visitID, now: now))
        #expect(restored.visitID == first.visitID)
        #expect(restored.placeContext == resolvedContext())
    }

    @Test("Late arrival enrichment updates the settled entry without restoring old sensor facts")
    func delayedArrivalEnrichmentPreservesDeparture() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let arrival = now.addingTimeInterval(-600)
        let ongoing = try makeVisit(arrivedAt: arrival, ongoing: true, capturedAt: now)
        store.record(ongoing, now: now)
        let settled = try makeVisit(arrivedAt: arrival, capturedAt: now.addingTimeInterval(120))
        store.record(settled, now: now.addingTimeInterval(120))

        let updated = try #require(store.applyPlaceContext(
            resolvedContext(), to: ongoing.visitID, now: now.addingTimeInterval(121)
        )?.visits.first)
        #expect(updated.visitID == ongoing.visitID)
        #expect(updated.state == .settled)
        #expect(updated.departedAt == settled.departedAt)
        #expect(updated.capturedAt == settled.capturedAt)
        #expect(updated.dwellSeconds == settled.dwellSeconds)
        #expect(updated.horizontalAccuracyMeters == settled.horizontalAccuracyMeters)
        #expect(updated.placeContext == resolvedContext())
        #expect(store.window(now: now).visits.count == 1)
    }

    @Test("Departure preserves enrichment and identity, and a delayed ongoing callback cannot regress it")
    func departurePreservesEnrichment() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let arrival = now.addingTimeInterval(-600)
        let ongoing = try makeVisit(arrivedAt: arrival, ongoing: true, capturedAt: now)
        store.record(ongoing, now: now)
        try store.applyPlaceContext(resolvedContext(), to: ongoing.visitID, now: now)
        let settled = try makeVisit(arrivedAt: arrival, capturedAt: now.addingTimeInterval(120))
        store.record(settled, now: now.addingTimeInterval(120))
        store.record(ongoing, now: now.addingTimeInterval(121))

        let updated = try #require(store.visit(id: ongoing.visitID, now: now))
        #expect(updated.state == .settled)
        #expect(updated.placeContext == resolvedContext())
        #expect(updated.capturedAt == settled.capturedAt)
        let restored = VisitWindowStore(fileURL: fixture.fileURL)
        #expect(restored.visit(id: ongoing.visitID, now: now) == updated)
    }

    @Test("Refining coordinates or accuracy retains the stay but invalidates old lookups", arguments: [true, false])
    func refinedLocationInvalidatesContext(changeCoordinates: Bool) throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let arrival = now.addingTimeInterval(-600)
        let ongoing = try makeVisit(arrivedAt: arrival, ongoing: true, capturedAt: now)
        store.record(ongoing, now: now)
        try store.applyPlaceContext(resolvedContext(), to: ongoing.visitID, now: now)
        let refined = try makeVisit(
            arrivedAt: arrival, capturedAt: now.addingTimeInterval(120),
            latitude: changeCoordinates ? ongoing.latitude + 0.0001 : ongoing.latitude,
            accuracy: changeCoordinates ? ongoing.horizontalAccuracyMeters : 3
        )
        let window = store.record(refined, now: now.addingTimeInterval(120))
        let current = try #require(window.visits.first)
        #expect(window.visits.count == 1)
        #expect(current.visitID == ongoing.visitID)
        #expect(current.state == .settled)
        #expect(current.latitude == refined.latitude)
        #expect(current.horizontalAccuracyMeters == refined.horizontalAccuracyMeters)
        #expect(current.placeContext == nil)
        #expect(try store.applyPlaceContext(
            resolvedContext(), to: ongoing.visitID, expectedVisit: ongoing,
            now: now.addingTimeInterval(121)
        ) == nil)
        #expect(store.visit(id: ongoing.visitID, now: now)?.placeContext == nil)
        let enriched = try store.applyPlaceContext(
            resolvedContext(), to: ongoing.visitID, expectedVisit: current,
            now: now.addingTimeInterval(122)
        )
        #expect(enriched?.visits.first?.placeContext == resolvedContext())
    }

    @Test("Legacy refined departures share an arrival identity and restore as one settled visit")
    func legacyRefinementCoalesces() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let arrival = now.addingTimeInterval(-600)
        let ongoing = try makeVisit(arrivedAt: arrival, ongoing: true, capturedAt: now)
        let settled = try makeVisit(
            arrivedAt: arrival, capturedAt: now.addingTimeInterval(120),
            latitude: ongoing.latitude + 0.0001, accuracy: 3
        )
        var legacy: [[String: Any]] = []
        for visit in [settled, ongoing] {
            let data = try ObservationCoding.encoder().encode(visit)
            var value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            value.removeValue(forKey: "visit_id")
            legacy.append(value)
        }
        let migrated = try legacy.map { value in
            try ObservationCoding.decoder().decode(
                VisitSnapshot.self, from: JSONSerialization.data(withJSONObject: value)
            )
        }
        #expect(migrated[0].visitID == migrated[1].visitID)
        try JSONSerialization.data(withJSONObject: ["visits": legacy]).write(to: fixture.fileURL)
        let restored = VisitWindowStore(fileURL: fixture.fileURL).window(now: now)
        #expect(restored.visits.count == 1)
        #expect(restored.visits.first?.state == .settled)
        #expect(restored.visits.first?.latitude == settled.latitude)
        #expect(restored.visits.first?.visitID == migrated[0].visitID)
    }

    @Test("Missed-arrival stays retain distinct identities when one receives enrichment")
    func missedArrivalsRemainSeparate() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let first = try makeVisit(arrivedAt: .distantPast, capturedAt: now.addingTimeInterval(-600))
        let second = try makeVisit(arrivedAt: .distantPast, capturedAt: now)
        store.record(first, now: now)
        store.record(second, now: now)
        try store.applyPlaceContext(resolvedContext(), to: first.visitID, now: now)

        #expect(first.visitID != second.visitID)
        #expect(store.window(now: now).visits.count == 2)
        #expect(store.visit(id: first.visitID, now: now)?.placeContext != nil)
        #expect(store.visit(id: second.visitID, now: now)?.placeContext == nil)
    }

    @Test("Enrichment never revives expired, evicted, or withdrawn entries")
    func absentEntriesCannotBeEnriched() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let visit = try makeVisit(capturedAt: now)
        store.record(visit, now: now)
        let expired = now.addingTimeInterval(VisitWindowSnapshot.windowHours * 3600 + 1)
        #expect(try store.applyPlaceContext(resolvedContext(), to: visit.visitID, now: expired) == nil)
        #expect(try store.applyPlaceContext(resolvedContext(), to: UUID(), now: now) == nil)

        for index in 1...VisitWindowSnapshot.maxEntries {
            store.record(try makeVisit(
                arrivedAt: .distantPast, capturedAt: now.addingTimeInterval(Double(index))
            ), now: now)
        }
        #expect(try store.applyPlaceContext(resolvedContext(), to: visit.visitID, now: now) == nil)
        let retainedID = try #require(store.window(now: now).visits.first?.visitID)
        store.discardAll()
        #expect(try store.applyPlaceContext(resolvedContext(), to: retainedID, now: now) == nil)
        #expect(store.isEmpty)
    }

    @Test("Removing enrichment retains raw visits and does not extend retention")
    func stripPreservesRawFactsAndExpiry() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let original = try makeVisit(capturedAt: now)
        store.record(original, now: now)
        try store.applyPlaceContext(resolvedContext(), to: original.visitID, now: now.addingTimeInterval(3_600))
        let stripped = try store.removePlaceContext(now: now.addingTimeInterval(7_200))
        #expect(stripped.visits == [original])
        #expect(VisitWindowStore(fileURL: fixture.fileURL).window(now: now).visits == [original])
        let expired = now.addingTimeInterval(VisitWindowSnapshot.windowHours * 3600 + 1)
        #expect(store.window(now: expired).visits.isEmpty)
    }

    @Test("Persistence errors roll back additions but keep revoked context out of memory")
    func persistenceFailureIsExplicit() throws {
        let fixture = try PlaceContextFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: fixture.fileURL)
        let original = try makeVisit(capturedAt: now)
        store.record(original, now: now)
        try store.applyPlaceContext(resolvedContext(), to: original.visitID, now: now)
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try store.applyPlaceContext(VisitPlaceContext(status: .pending), to: original.visitID, now: now)
        }
        #expect(store.visit(id: original.visitID, now: now)?.placeContext == resolvedContext())
        #expect(throws: (any Error).self) {
            try store.removePlaceContext(now: now)
        }
        #expect(store.visit(id: original.visitID, now: now)?.placeContext == nil)
    }

    @Test("Context bounding drops candidates first and preserves complete attribution")
    func boundsCandidatesBeforeAddressAndAttribution() throws {
        let attribution = [VisitPlaceAttribution(text: "Example map data", url: "https://example.com/license")]
        let context = VisitPlaceContext(
            status: .resolved, provider: "example",
            address: VisitPlaceAddress(formatted: "123 Main Street"),
            placeCandidates: (0..<8).map { index in
                VisitPlaceCandidate(
                    name: String(repeating: "Long name \(index)", count: 100),
                    latitude: 29.8, longitude: -98.4
                )
            },
            attribution: attribution
        )
        #expect(context.truncated)
        #expect(context.placeCandidates.isEmpty)
        #expect(context.address?.formatted == "123 Main Street")
        #expect(context.attribution == attribution)
        #expect(try JSONEncoder().encode(context).count <= VisitPlaceContext.maxEncodedBytes)
    }

    @Test("Oversized attribution rejects derived data without publishing an incomplete license")
    func oversizedAttributionFailsClosed() throws {
        let context = VisitPlaceContext(
            status: .resolved, provider: "example", address: VisitPlaceAddress(formatted: "123 Main Street"),
            attribution: [VisitPlaceAttribution(text: String(repeating: "License ", count: 400))]
        )
        #expect(context.status == .unavailable)
        #expect(context.failureReason == .contextTooLarge)
        #expect(context.truncated)
        #expect(context.address == nil)
        #expect(context.placeCandidates.isEmpty)
        #expect(context.attribution.isEmpty)
        #expect(try JSONEncoder().encode(context).count <= VisitPlaceContext.maxEncodedBytes)
    }

    @Test("UTF-8 and JSON escaping stay within the byte budget on construction and decoding")
    func encodedBudgetIncludesEscaping() throws {
        let context = VisitPlaceContext(
            status: .resolved, provider: String(repeating: "\u{0001}", count: 200),
            attemptedAt: String(repeating: "\u{0001}", count: 100),
            resolvedAt: String(repeating: "\u{0001}", count: 100),
            address: VisitPlaceAddress(formatted: String(repeating: "🏔️\"\\", count: 300)),
            attribution: [VisitPlaceAttribution(text: String(repeating: "\u{0001}", count: 300))]
        )
        #expect(context.truncated)
        let data = try JSONEncoder().encode(context)
        #expect(data.count <= VisitPlaceContext.maxEncodedBytes)
        let decoded = try JSONDecoder().decode(VisitPlaceContext.self, from: data)
        #expect(decoded == context)

        let oversized = try JSONSerialization.data(withJSONObject: [
            "status": "resolved",
            "address": ["formatted": String(repeating: "🏔️", count: 500)],
            "attribution": [["text": "Example map data"]],
        ])
        let normalized = try JSONDecoder().decode(VisitPlaceContext.self, from: oversized)
        #expect(normalized.truncated)
        #expect(try JSONEncoder().encode(normalized).count <= VisitPlaceContext.maxEncodedBytes)
        #expect(normalized.attribution.first?.text == "Example map data")
    }

    private func resolvedContext() -> VisitPlaceContext {
        VisitPlaceContext(
            status: .resolved, provider: "example",
            attemptedAt: ObservationCoding.dateString(from: now),
            resolvedAt: ObservationCoding.dateString(from: now),
            address: VisitPlaceAddress(formatted: "123 Main Street", locality: "Example City"),
            attribution: [VisitPlaceAttribution(text: "Example map data")]
        )
    }

    private func makeVisit(
        arrivedAt: Date? = nil, ongoing: Bool = false, capturedAt: Date,
        latitude: Double = 29.8312, accuracy: Double = 12
    ) throws -> VisitSnapshot {
        try #require(VisitSnapshot.make(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -98.4643),
            horizontalAccuracy: accuracy,
            arrivalDate: arrivedAt ?? capturedAt.addingTimeInterval(-600),
            departureDate: ongoing ? .distantFuture : capturedAt,
            capturedAt: capturedAt
        ))
    }
}

private struct PlaceContextFixture {
    let directory: URL
    let fileURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisitPlaceContextTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("window.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
