import CoreLocation
import Foundation
import MapKit
import Testing
@testable import ThaneIOSCompanion

@Suite("Apple visit place resolution")
@MainActor
struct AppleVisitPlaceResolverTests {
    @Test("Search radius uses the recorded uncertainty within fixed limits", arguments: [
        (0.0, 100.0), (50.0, 100.0), (250.0, 250.0), (2_000.0, 1_000.0),
    ])
    func searchRadius(input: (Double, Double)) async throws {
        let lookup = StubAppleVisitLookup()
        let context = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit(accuracy: input.0))
        #expect(lookup.lastRadius == input.1)
        #expect(context.searchRadiusMeters == input.1)
        #expect(context.status == .noMatch)
        #expect(!context.partial)
    }

    @Test("Nearby candidates are valid, within the radius, deduplicated, and nearest first")
    func ranksAndBoundsCandidates() async throws {
        let lookup = StubAppleVisitLookup()
        lookup.places = .success([
            AppleVisitPlace(id: "farther", name: "Farther", latitude: 0.0003, longitude: 0),
            AppleVisitPlace(id: "middle", name: "Middle", latitude: 0.0002, longitude: 0),
            AppleVisitPlace(id: "nearest", name: "Nearest", category: "MKPOICategoryCafe", latitude: 0.0001, longitude: 0),
            AppleVisitPlace(id: "nearest", name: "Duplicate", latitude: 0.0004, longitude: 0),
            AppleVisitPlace(id: "fourth", name: "Fourth", latitude: 0.0005, longitude: 0),
            AppleVisitPlace(id: "invalid", latitude: .nan, longitude: 0),
            AppleVisitPlace(id: "invalid-range", latitude: 91, longitude: 0),
            AppleVisitPlace(id: "invalid-infinite", latitude: 0, longitude: .infinity),
            AppleVisitPlace(id: "outside", latitude: 1, longitude: 0),
        ])
        let context = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit())
        #expect(context.status == .resolved)
        #expect(context.provider == "apple_maps")
        #expect(context.truncated)
        #expect(context.partial)
        #expect(context.placeCandidates.map(\.id) == ["nearest", "middle", "farther"])
        let nearest = try #require(context.placeCandidates.first)
        #expect(nearest.latitude == 0.0001)
        #expect(nearest.longitude == 0)
        #expect(nearest.name == "Nearest")
        #expect(nearest.categories == ["MKPOICategoryCafe"])
        let expected = CLLocation(latitude: 0, longitude: 0)
            .distance(from: CLLocation(latitude: 0.0001, longitude: 0))
        #expect(nearest.distanceMeters == expected)
        #expect(context.attribution.first?.text == "Apple Maps")
    }

    @Test("Address data survives a failed POI lookup")
    func addressOnlyOnPartialFailure() async throws {
        let lookup = StubAppleVisitLookup()
        let address = VisitPlaceAddress(formatted: "Example Address", locality: "Example City")
        lookup.address = .success(address)
        lookup.places = .failure(AppleLookupTestError.unavailable)
        let context = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit())
        #expect(context.status == .resolved)
        #expect(context.address == address)
        #expect(context.placeCandidates.isEmpty)
        #expect(context.partial)
    }

    @Test("POI data survives a failed reverse geocode")
    func placesOnlyOnPartialFailure() async throws {
        let lookup = StubAppleVisitLookup()
        lookup.address = .failure(AppleLookupTestError.unavailable)
        lookup.places = .success([AppleVisitPlace(id: "place", latitude: 0, longitude: 0)])
        let context = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit())
        #expect(context.status == .resolved)
        #expect(context.address == nil)
        #expect(context.placeCandidates.first?.id == "place")
        #expect(context.partial)
    }

    @Test("Lookup errors and malformed results do not claim that there was no match")
    func failuresAreUnavailable() async throws {
        let lookup = StubAppleVisitLookup()
        lookup.address = .failure(AppleLookupTestError.unavailable)
        lookup.places = .failure(AppleLookupTestError.unavailable)
        let failed = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit())
        #expect(failed.status == .unavailable)
        #expect(failed.partial)
        #expect(failed.attribution.isEmpty)
        lookup.address = .success(nil)
        lookup.places = .success([AppleVisitPlace(latitude: .nan, longitude: 0)])
        let malformed = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit())
        #expect(malformed.status == .unavailable)
        #expect(malformed.partial)
    }

    @Test("MapKit's explicit not-found error is an empty result, not a service outage")
    func mapKitNoMatch() async throws {
        let lookup = StubAppleVisitLookup()
        let error = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue))
        lookup.address = .failure(error)
        lookup.places = .failure(error)
        let context = try await AppleVisitPlaceResolver(lookup: lookup).resolve(visit())
        #expect(context.status == .noMatch)
        #expect(!context.partial)
    }

    @Test("Invalid source coordinates or uncertainty never reach MapKit", arguments: [
        (Double.nan, 0.0, 10.0), (91.0, 0.0, 10.0), (0.0, 181.0, 10.0),
        (0.0, 0.0, Double.infinity), (0.0, 0.0, -1.0),
    ])
    func invalidInput(input: (Double, Double, Double)) async {
        let lookup = StubAppleVisitLookup()
        do {
            _ = try await AppleVisitPlaceResolver(lookup: lookup).resolve(
                visit(latitude: input.0, longitude: input.1, accuracy: input.2)
            )
            Issue.record("An invalid visit must fail before starting lookup")
        } catch {
            #expect(lookup.reverseCalls == 0)
            #expect(lookup.nearbyCalls == 0)
        }
    }

    @Test("Cancellation before resolution starts sends no lookup")
    func cancelledBeforeStart() async throws {
        let lookup = StubAppleVisitLookup()
        let resolver = AppleVisitPlaceResolver(lookup: lookup)
        let input = visit()
        let task = Task { try await resolver.resolve(input) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled lookup unexpectedly completed")
        } catch is CancellationError {
            #expect(lookup.reverseCalls == 0)
            #expect(lookup.nearbyCalls == 0)
        }
    }

    @Test("Cancellation during reverse geocoding does not start the POI request")
    func cancelledBetweenRequests() async throws {
        let lookup = DeferredAppleVisitLookup()
        let resolver = AppleVisitPlaceResolver(lookup: lookup)
        let input = visit()
        let task = Task { try await resolver.resolve(input) }
        try await waitUntil { lookup.pending != nil }
        task.cancel()
        lookup.pending?.resume(returning: VisitPlaceAddress(formatted: "Example Address"))
        lookup.pending = nil
        do {
            _ = try await task.value
            Issue.record("Cancelled lookup unexpectedly completed")
        } catch is CancellationError {
            #expect(lookup.nearbyCalls == 0)
        }
    }

    @Test("Native request cancellation runs once and tolerates a late callback")
    func nativeCancellation() async throws {
        let probe = AppleRequestProbe()
        let request = AppleVisitMapRequest<Int>(cancel: { probe.cancelCount += 1 }) { completion in
            probe.startCount += 1
            probe.completion = completion
        }
        let task = Task { try await request.value() }
        try await waitUntil { probe.startCount == 1 }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled request unexpectedly completed")
        } catch is CancellationError {
            #expect(probe.cancelCount == 1)
        }
        probe.completion?(.success(42))
        #expect(probe.cancelCount == 1)
    }

    @Test("A previously cancelled task cannot start the native request")
    func nativePrecancelled() async throws {
        let probe = AppleRequestProbe()
        let request = AppleVisitMapRequest<Int>(cancel: { probe.cancelCount += 1 }) { completion in
            probe.startCount += 1
            completion(.success(42))
        }
        let task = Task { try await request.value() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled request unexpectedly completed")
        } catch is CancellationError {
            #expect(probe.startCount == 0)
        }
    }

    private func visit(latitude: Double = 0, longitude: Double = 0, accuracy: Double = 10) -> VisitSnapshot {
        VisitSnapshot(
            latitude: latitude, longitude: longitude, horizontalAccuracyMeters: accuracy,
            arrival: .unknown, arrivedAt: nil, departedAt: nil, state: .ongoing,
            dwellSeconds: nil, dwellIsPartial: true, capturedAt: "2026-09-19T12:00:00.000Z"
        )
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for lookup fixture")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class StubAppleVisitLookup: AppleVisitPlaceLookup {
    var address: Result<VisitPlaceAddress?, any Error> = .success(nil)
    var places: Result<[AppleVisitPlace], any Error> = .success([])
    var reverseCalls = 0
    var nearbyCalls = 0
    var lastRadius: Double?

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> VisitPlaceAddress? {
        reverseCalls += 1
        return try address.get()
    }

    func nearbyPlaces(latitude: Double, longitude: Double, radiusMeters: Double) async throws -> [AppleVisitPlace] {
        nearbyCalls += 1
        lastRadius = radiusMeters
        return try places.get()
    }
}

@MainActor
private final class DeferredAppleVisitLookup: AppleVisitPlaceLookup {
    var pending: CheckedContinuation<VisitPlaceAddress?, any Error>?
    var nearbyCalls = 0

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> VisitPlaceAddress? {
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func nearbyPlaces(latitude: Double, longitude: Double, radiusMeters: Double) async throws -> [AppleVisitPlace] {
        nearbyCalls += 1
        return []
    }
}

@MainActor
private final class AppleRequestProbe {
    var startCount = 0
    var cancelCount = 0
    var completion: AppleVisitMapRequest<Int>.Completion?
}

private enum AppleLookupTestError: Error {
    case unavailable
}
