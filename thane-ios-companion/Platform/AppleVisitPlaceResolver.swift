import CoreLocation
import Foundation
import MapKit

/// Plain values keep MapKit objects inside the native lookup boundary.
nonisolated struct AppleVisitPlace: Sendable {
    let id: String?
    let name: String?
    let category: String?
    let latitude: Double
    let longitude: Double
    let address: VisitPlaceAddress?

    init(
        id: String? = nil, name: String? = nil, category: String? = nil,
        latitude: Double, longitude: Double, address: VisitPlaceAddress? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }
}

@MainActor
protocol AppleVisitPlaceLookup: Sendable {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> VisitPlaceAddress?
    func nearbyPlaces(
        latitude: Double, longitude: Double, radiusMeters: Double
    ) async throws -> [AppleVisitPlace]
}

@MainActor
final class AppleVisitPlaceResolver: VisitPlaceResolving {
    let provider = "apple_maps"
    private let lookup: any AppleVisitPlaceLookup

    init(lookup: any AppleVisitPlaceLookup = MapKitVisitPlaceLookup()) {
        self.lookup = lookup
    }

    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        try Task.checkCancellation()
        guard Self.validCoordinate(latitude: visit.latitude, longitude: visit.longitude),
              visit.horizontalAccuracyMeters.isFinite, visit.horizontalAccuracyMeters >= 0 else {
            throw AppleVisitLookupError.invalidLocation
        }
        let radius = min(1_000, max(100, visit.horizontalAccuracyMeters))
        var address: VisitPlaceAddress?
        var places: [AppleVisitPlace] = []
        var partial = false
        do {
            address = try await lookup.reverseGeocode(latitude: visit.latitude, longitude: visit.longitude)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            partial = !Self.isNoMatch(error)
        }
        try Task.checkCancellation()
        do {
            places = try await lookup.nearbyPlaces(
                latitude: visit.latitude, longitude: visit.longitude, radiusMeters: radius
            )
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            partial = partial || !Self.isNoMatch(error)
        }
        try Task.checkCancellation()

        let origin = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        let candidates = places.compactMap { place -> VisitPlaceCandidate? in
            guard Self.validCoordinate(latitude: place.latitude, longitude: place.longitude) else {
                partial = true
                return nil
            }
            let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = origin.distance(from: location)
            guard distance.isFinite, distance >= 0, distance <= radius else { return nil }
            return VisitPlaceCandidate(
                id: place.id, name: place.name, categories: place.category.map { [$0] } ?? [],
                latitude: place.latitude, longitude: place.longitude,
                distanceMeters: distance, address: place.address
            )
        }.sorted {
            if $0.distanceMeters != $1.distanceMeters {
                return ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity)
            }
            return Self.orderingKey($0) < Self.orderingKey($1)
        }
        var identifiers = Set<String>()
        var unidentified = Set<String>()
        let unique = candidates.filter { candidate in
            if let id = candidate.id, !id.isEmpty { return identifiers.insert(id).inserted }
            return unidentified.insert(Self.orderingKey(candidate)).inserted
        }
        let hasDetails = address != nil || !unique.isEmpty
        return VisitPlaceContext(
            status: hasDetails ? .resolved : (partial ? .unavailable : .noMatch),
            provider: provider,
            address: address,
            placeCandidates: Array(unique.prefix(VisitPlaceContext.maxCandidates)),
            attribution: hasDetails ? [VisitPlaceAttribution(text: "Apple Maps", url: "https://maps.apple.com/")] : [],
            truncated: unique.count > VisitPlaceContext.maxCandidates,
            searchRadiusMeters: radius,
            partial: partial
        )
    }

    private static func validCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func isNoMatch(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == MKErrorDomain && error.code == Int(MKError.Code.placemarkNotFound.rawValue)
    }

    private static func orderingKey(_ candidate: VisitPlaceCandidate) -> String {
        "\(candidate.id ?? "")|\(candidate.name ?? "")|\(candidate.latitude)|\(candidate.longitude)"
    }
}

@MainActor
final class MapKitVisitPlaceLookup: AppleVisitPlaceLookup {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> VisitPlaceAddress? {
        try Task.checkCancellation()
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: latitude, longitude: longitude)
        ) else { throw AppleVisitLookupError.invalidLocation }
        let operation = AppleVisitMapRequest<VisitPlaceAddress?>(cancel: { request.cancel() }) { complete in
            request.getMapItems { items, error in
                if let error { complete(.failure(error)); return }
                complete(.success(items?.compactMap(Self.address).first))
            }
        }
        return try await operation.value()
    }

    func nearbyPlaces(
        latitude: Double, longitude: Double, radiusMeters: Double
    ) async throws -> [AppleVisitPlace] {
        try Task.checkCancellation()
        let request = MKLocalPointsOfInterestRequest(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: radiusMeters
        )
        let search = MKLocalSearch(request: request)
        let operation = AppleVisitMapRequest<[AppleVisitPlace]>(cancel: { search.cancel() }) { complete in
            search.start { response, error in
                if let error { complete(.failure(error)); return }
                let places = response?.mapItems.map { item in
                    AppleVisitPlace(
                        id: item.identifier?.rawValue, name: item.name,
                        category: item.pointOfInterestCategory?.rawValue,
                        latitude: item.location.coordinate.latitude,
                        longitude: item.location.coordinate.longitude,
                        address: Self.address(item)
                    )
                } ?? []
                complete(.success(places))
            }
        }
        return try await operation.value()
    }

    private static func address(_ item: MKMapItem) -> VisitPlaceAddress? {
        let representations = item.addressRepresentations
        guard let formatted = item.address?.fullAddress
            ?? representations?.fullAddress(includingRegion: true, singleLine: true),
              !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return VisitPlaceAddress(
            formatted: formatted, locality: representations?.cityName,
            country: representations?.regionName, countryCode: representations?.region?.identifier
        )
    }
}

/// Explicit cancellation stops MapKit and does not depend on a later callback.
@MainActor
final class AppleVisitMapRequest<Value: Sendable> {
    typealias Completion = @MainActor @Sendable (Result<Value, any Error>) -> Void
    private let cancelRequest: @MainActor () -> Void
    private let start: @MainActor (@escaping Completion) -> Void
    private var continuation: CheckedContinuation<Value, any Error>?
    private var finished = false

    init(
        cancel: @escaping @MainActor () -> Void,
        start: @escaping @MainActor (@escaping Completion) -> Void
    ) {
        cancelRequest = cancel
        self.start = start
    }

    func value() async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !finished else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                start { [weak self] in self?.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func cancel() {
        guard !finished else { return }
        cancelRequest()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, any Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }
}

private enum AppleVisitLookupError: Error {
    case invalidLocation
}
