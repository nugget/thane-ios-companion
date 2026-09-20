import CoreLocation
import CryptoKit
import Foundation

/// Whether an arrival time is real or was never observed.
///
/// CoreLocation signals a missed arrival with `Date.distantPast`, which is a
/// sentinel rather than a time. Passing it through would be a lie the reader
/// cannot detect, and — because it predates the server's 2000-01-01 floor —
/// using it as an event timestamp rejects the whole upload batch, taking
/// unrelated location and system-context events down with it.
nonisolated enum VisitBoundary: String, Codable, Sendable {
    case precise
    case unknown
}

/// Whether the operator has left this place yet.
nonisolated enum VisitState: String, Codable, Sendable {
    case settled
    case ongoing
}

nonisolated enum VisitPlaceContextStatus: String, Codable, Sendable {
    case pending
    case resolved
    case noMatch = "no_match"
    case unavailable
}

nonisolated struct VisitPlaceAddress: Codable, Equatable, Sendable {
    let formatted: String?
    let streetNumber: String?
    let street: String?
    let locality: String?
    let region: String?
    let postalCode: String?
    let country: String?
    let countryCode: String?

    init(
        formatted: String? = nil, streetNumber: String? = nil, street: String? = nil,
        locality: String? = nil, region: String? = nil, postalCode: String? = nil,
        country: String? = nil, countryCode: String? = nil
    ) {
        self.formatted = formatted
        self.streetNumber = streetNumber
        self.street = street
        self.locality = locality
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.countryCode = countryCode
    }

    enum CodingKeys: String, CodingKey {
        case formatted, street, locality, region, country
        case streetNumber = "street_number"
        case postalCode = "postal_code"
        case countryCode = "country_code"
    }
}

/// A nearby place is a candidate, not evidence that the operator visited it.
nonisolated struct VisitPlaceCandidate: Codable, Equatable, Sendable {
    let id: String?
    let name: String?
    let categories: [String]
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double?
    let address: VisitPlaceAddress?

    init(
        id: String? = nil, name: String? = nil, categories: [String] = [],
        latitude: Double, longitude: Double, distanceMeters: Double? = nil,
        address: VisitPlaceAddress? = nil
    ) {
        self.id = id
        self.name = name
        self.categories = categories
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.address = address
    }

    enum CodingKeys: String, CodingKey {
        case id, name, categories, latitude, longitude, address
        case distanceMeters = "distance_meters"
    }
}

nonisolated struct VisitPlaceAttribution: Codable, Equatable, Sendable {
    let text: String
    let url: String?

    init(text: String, url: String? = nil) {
        self.text = text
        self.url = url
    }
}

nonisolated struct VisitPlaceContext: Codable, Equatable, Sendable {
    static let maxCandidates = 3
    static let maxEncodedBytes = 1_200

    private(set) var status: VisitPlaceContextStatus
    let provider: String?
    let attemptedAt: String?
    let resolvedAt: String?
    let searchRadiusMeters: Double?
    let partial: Bool
    private(set) var address: VisitPlaceAddress?
    private(set) var placeCandidates: [VisitPlaceCandidate]
    private(set) var attribution: [VisitPlaceAttribution]
    private(set) var truncated: Bool
    private(set) var failureReason: VisitPlaceContextFailureReason?

    init(
        status: VisitPlaceContextStatus, provider: String? = nil,
        attemptedAt: String? = nil, resolvedAt: String? = nil,
        address: VisitPlaceAddress? = nil, placeCandidates: [VisitPlaceCandidate] = [],
        attribution: [VisitPlaceAttribution] = [], truncated: Bool = false,
        failureReason: VisitPlaceContextFailureReason? = nil,
        searchRadiusMeters: Double? = nil, partial: Bool = false
    ) {
        self.status = status
        self.provider = Self.shortened(provider, to: 80)
        self.attemptedAt = Self.shortened(attemptedAt, to: 40)
        self.resolvedAt = Self.shortened(resolvedAt, to: 40)
        self.searchRadiusMeters = searchRadiusMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.partial = partial
        self.address = address
        self.placeCandidates = Array(placeCandidates.prefix(Self.maxCandidates))
        self.attribution = attribution
        self.truncated = truncated || placeCandidates.count > Self.maxCandidates
            || self.provider != provider || self.attemptedAt != attemptedAt || self.resolvedAt != resolvedAt
        self.failureReason = failureReason
        enforceBudget()
    }

    enum CodingKeys: String, CodingKey {
        case status, provider, address, attribution, truncated, partial
        case searchRadiusMeters = "search_radius_meters"
        case attemptedAt = "attempted_at"
        case resolvedAt = "resolved_at"
        case placeCandidates = "place_candidates"
        case failureReason = "failure_reason"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            status: try values.decode(VisitPlaceContextStatus.self, forKey: .status),
            provider: try values.decodeIfPresent(String.self, forKey: .provider),
            attemptedAt: try values.decodeIfPresent(String.self, forKey: .attemptedAt),
            resolvedAt: try values.decodeIfPresent(String.self, forKey: .resolvedAt),
            address: try values.decodeIfPresent(VisitPlaceAddress.self, forKey: .address),
            placeCandidates: try values.decodeIfPresent([VisitPlaceCandidate].self, forKey: .placeCandidates) ?? [],
            attribution: try values.decodeIfPresent([VisitPlaceAttribution].self, forKey: .attribution) ?? [],
            truncated: try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
            failureReason: try values.decodeIfPresent(VisitPlaceContextFailureReason.self, forKey: .failureReason),
            searchRadiusMeters: try values.decodeIfPresent(Double.self, forKey: .searchRadiusMeters),
            partial: try values.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        )
    }

    private mutating func enforceBudget() {
        while !placeCandidates.isEmpty, encodedSize.map({ $0 > Self.maxEncodedBytes }) ?? true {
            placeCandidates.removeLast()
            truncated = true
        }
        if status == .resolved, address == nil, placeCandidates.isEmpty, truncated {
            status = .unavailable
            attribution = []
            failureReason = .contextTooLarge
        }
        if let size = encodedSize, size <= Self.maxEncodedBytes { return }

        // Keep attribution intact. Address components may be abbreviated,
        // with truncation disclosed, before dropping the derived result.
        for limit in [128, 64] {
            if let address {
                self.address = VisitPlaceAddress(
                    formatted: Self.shortened(address.formatted, to: limit),
                    streetNumber: Self.shortened(address.streetNumber, to: limit),
                    street: Self.shortened(address.street, to: limit),
                    locality: Self.shortened(address.locality, to: limit),
                    region: Self.shortened(address.region, to: limit),
                    postalCode: Self.shortened(address.postalCode, to: limit),
                    country: Self.shortened(address.country, to: limit),
                    countryCode: Self.shortened(address.countryCode, to: limit)
                )
                truncated = true
            }
            if let size = encodedSize, size <= Self.maxEncodedBytes { return }
        }

        // Oversized attribution cannot be shortened without potentially
        // losing a licensing requirement. Remove all derived data together.
        status = .unavailable
        address = nil
        placeCandidates = []
        attribution = []
        truncated = true
        failureReason = .contextTooLarge
    }

    private var encodedSize: Int? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.count
    }

    private static func shortened(_ value: String?, to maxBytes: Int) -> String? {
        guard let value, value.utf8.count > maxBytes else { return value }
        var result = ""
        for scalar in value.unicodeScalars {
            let next = String(scalar)
            guard result.utf8.count + next.utf8.count <= maxBytes else { break }
            result += next
        }
        return result
    }
}

nonisolated enum VisitPlaceContextFailureReason: String, Codable, Sendable {
    case contextTooLarge = "context_too_large"
}

/// One visit: somewhere the operator lingered, and for how long.
nonisolated struct VisitSnapshot: Codable, Equatable, Sendable {
    var visitID: UUID
    var placeContext: VisitPlaceContext?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double
    let arrival: VisitBoundary
    let arrivedAt: String?
    let departedAt: String?
    let state: VisitState
    let dwellSeconds: Double?
    let dwellIsPartial: Bool
    /// When this device observed the visit. Recorded because it is the only
    /// timestamp guaranteed to exist: a departure is absent while ongoing and
    /// an arrival is absent when missed.
    let capturedAt: String

    init(
        latitude: Double, longitude: Double, horizontalAccuracyMeters: Double,
        arrival: VisitBoundary, arrivedAt: String?, departedAt: String?, state: VisitState,
        dwellSeconds: Double?, dwellIsPartial: Bool, capturedAt: String,
        visitID: UUID = UUID(), placeContext: VisitPlaceContext? = nil
    ) {
        self.visitID = visitID
        self.placeContext = placeContext
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.arrival = arrival
        self.arrivedAt = arrivedAt
        self.departedAt = departedAt
        self.state = state
        self.dwellSeconds = dwellSeconds
        self.dwellIsPartial = dwellIsPartial
        self.capturedAt = capturedAt
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, arrival, state
        case visitID = "visit_id"
        case placeContext = "place_context"
        case horizontalAccuracyMeters = "horizontal_accuracy_meters"
        case arrivedAt = "arrived_at"
        case departedAt = "departed_at"
        case dwellSeconds = "dwell_seconds"
        case dwellIsPartial = "dwell_is_partial"
        case capturedAt = "captured_at"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try values.decode(Double.self, forKey: .latitude)
        longitude = try values.decode(Double.self, forKey: .longitude)
        horizontalAccuracyMeters = try values.decode(Double.self, forKey: .horizontalAccuracyMeters)
        arrival = try values.decode(VisitBoundary.self, forKey: .arrival)
        arrivedAt = try values.decodeIfPresent(String.self, forKey: .arrivedAt)
        departedAt = try values.decodeIfPresent(String.self, forKey: .departedAt)
        state = try values.decode(VisitState.self, forKey: .state)
        dwellSeconds = try values.decodeIfPresent(Double.self, forKey: .dwellSeconds)
        dwellIsPartial = try values.decode(Bool.self, forKey: .dwellIsPartial)
        capturedAt = try values.decode(String.self, forKey: .capturedAt)
        placeContext = try values.decodeIfPresent(VisitPlaceContext.self, forKey: .placeContext)
        visitID = try values.decodeIfPresent(UUID.self, forKey: .visitID) ?? Self.legacyID(
            latitude: latitude, longitude: longitude, arrivedAt: arrivedAt,
            departedAt: departedAt, capturedAt: capturedAt
        )
    }

    /// Old windows need stable identities even when they cannot immediately
    /// be rewritten. The observation time distinguishes missed-arrival stays.
    private static func legacyID(
        latitude: Double, longitude: Double, arrivedAt: String?,
        departedAt: String?, capturedAt: String
    ) -> UUID {
        let components: [String]
        if let arrivedAt {
            components = ["thane-legacy-visit-arrival", arrivedAt]
        } else {
            components = [
                "thane-legacy-visit", String(latitude.bitPattern), String(longitude.bitPattern),
                departedAt ?? "", capturedAt,
            ]
        }
        let identity = components.joined(separator: "\n")
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The instant this visit is anchored to for ordering and pruning: the
    /// departure when settled, the capture time otherwise.
    ///
    /// Deliberately not the arrival. An ongoing stay that began three days ago
    /// is current, not stale, and anchoring it to its arrival pruned it on
    /// sight; a missed arrival has no timestamp at all and fell back to
    /// `.distantPast`, which pruned it immediately. Capture time is the one
    /// value always present and always meaningful.
    /// The `state` check guards a decoded record only: `make` derives state
    /// and departure from one condition, so they cannot disagree in memory.
    var anchorDate: Date {
        if state == .settled, let departedAt,
           let parsed = ObservationCoding.date(from: departedAt) {
            return parsed
        }
        return ObservationCoding.date(from: capturedAt) ?? .distantPast
    }

    /// Identity for ongoing-to-settled replacement. Core Location delivers the
    /// same stay twice, but only a real arrival distinguishes one stay from
    /// another — every missed arrival is nil, so matching on it would collapse
    /// unrelated visits together.
    var stayKey: String? {
        arrivedAt
    }

    /// A refined fix keeps the stay identity but invalidates lookup results,
    /// including searches whose radius depends on horizontal accuracy.
    func hasSameLookupLocation(as other: VisitSnapshot) -> Bool {
        latitude == other.latitude && longitude == other.longitude
            && horizontalAccuracyMeters == other.horizontalAccuracyMeters
    }

    /// Built from CoreLocation's scalars rather than from `CLVisit` itself.
    ///
    /// `CLVisit` has no public initialiser, so a builder taking one cannot be
    /// exercised in a test. Taking the four values it carries keeps every
    /// sentinel and boundary decision testable, and leaves the delegate a
    /// two-line adapter.
    static func make(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: CLLocationAccuracy,
        arrivalDate: Date,
        departureDate: Date,
        capturedAt: Date
    ) -> VisitSnapshot? {
        guard CLLocationCoordinate2DIsValid(coordinate), horizontalAccuracy >= 0 else {
            return nil
        }
        let arrivalKnown = arrivalDate != .distantPast
        let departed = departureDate != .distantFuture
        let departureInstant = departed ? departureDate : capturedAt

        var dwell: Double?
        if arrivalKnown {
            dwell = max(0, departureInstant.timeIntervalSince(arrivalDate))
        }

        return VisitSnapshot(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracyMeters: horizontalAccuracy,
            arrival: arrivalKnown ? .precise : .unknown,
            arrivedAt: arrivalKnown ? ObservationCoding.dateString(from: arrivalDate) : nil,
            departedAt: departed ? ObservationCoding.dateString(from: departureDate) : nil,
            state: departed ? .settled : .ongoing,
            dwellSeconds: dwell,
            dwellIsPartial: !departed,
            capturedAt: ObservationCoding.dateString(from: capturedAt)
        )
    }
}

/// A bounded window of recent visits, republished whole on every change.
///
/// It has to be a list rather than one visit per event: the outbox keeps a
/// single event per kind (`eventsByKind`), so two visits settling between
/// flushes would silently discard the first. Re-sending the window makes the
/// latest row self-superseding and lossless within its bounds.
nonisolated struct VisitWindowSnapshot: Codable, Equatable, Sendable {
    static let maxEntries = 16
    static let windowHours = 48.0

    let capturedAt: String
    let windowHours: Double
    let maxEntries: Int
    let returnedCount: Int
    let truncated: Bool
    let visits: [VisitSnapshot]

    func withoutPlaceContext() -> VisitWindowSnapshot {
        VisitWindowSnapshot(
            capturedAt: capturedAt, windowHours: windowHours, maxEntries: maxEntries,
            returnedCount: returnedCount, truncated: truncated,
            visits: visits.map { visit in
                var raw = visit
                raw.placeContext = nil
                return raw
            }
        )
    }

    enum CodingKeys: String, CodingKey {
        case visits, truncated
        case capturedAt = "captured_at"
        case windowHours = "window_hours"
        case maxEntries = "max_entries"
        case returnedCount = "returned_count"
    }
}
