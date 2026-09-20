import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Cold launch location withdrawal")
@MainActor
struct ColdLaunchVisitWithdrawalTests {
    @Test(
        "A cold launch withdraws acknowledged observations after Always access is lost",
        arguments: ["whenInUse", "denied"]
    )
    func authorizationLossWithdrawsWithoutForeground(authorization: String) async throws {
        let status: CLAuthorizationStatus = authorization == "whenInUse" ? .authorizedWhenInUse : .denied
        let fixture = try await ColdLaunchWithdrawalFixture(authorization: status)
        defer { fixture.cleanup() }

        // No activate(), scene transition, or delegate notification follows
        // initialization: recovery must work in the launch itself.
        #expect(fixture.profile.visitWindow.isEmpty)
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.resolver.calls == 0)
        #expect(fixture.fetcher.calls == 0)
        #expect(VisitWindowStore(fileURL: fixture.windowURL).window().visits.isEmpty)
        try await waitUntil {
            let pending = try await fixture.pending()
            return pending.first(where: { $0.kind == .visits })?.status == .withdrawn
                && pending.first(where: { $0.kind == .location })?.status == .withdrawn
        }

        // Let other launch-time queue operations finish as well. An empty
        // available window must not supersede the withdrawal on their tail.
        try await Task.sleep(for: .milliseconds(100))
        let persisted = try await fixture.persistedPending()
        let visits = try #require(persisted.first { $0.kind == .visits })
        let location = try #require(persisted.first { $0.kind == .location })
        #expect(visits.status == .withdrawn)
        #expect(visits.payload == nil)
        #expect(location.status == .withdrawn)
        #expect(location.payload == nil)
        #expect(fixture.profile.visitWindow.isEmpty)
        #expect(fixture.resolver.calls == 0)
        #expect(fixture.fetcher.calls == 0)
        #expect(fixture.uploader.calls == 0)
    }

    private func waitUntil(_ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            if try await predicate() { return }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for cold-launch withdrawals")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class ColdLaunchWithdrawalFixture {
    let profile: AgentProfile
    let windowURL: URL
    let resolver = ColdLaunchPlaceResolver()
    let fetcher = ColdLaunchIdentityFetcher()
    let uploader = ColdLaunchObservationUploader()
    private let outbox: ObservationOutbox
    private let outboxURL: URL
    private let scope: ObservationDeliveryScope
    private let suite: String
    private let defaults: UserDefaults
    private let directory: URL

    init(authorization: CLAuthorizationStatus) async throws {
        suite = "ColdLaunchVisitWithdrawalTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        windowURL = directory.appendingPathComponent("visits.json")
        outboxURL = directory.appendingPathComponent("outbox.json")
        let endpoint = try #require(URL(string: "https://thane.example"))
        let evidence = try IdentityTestFixture.freshEvidence()
        let secureStore = ColdLaunchCredentialStore()
        let settings = ConnectionSettings(
            profileID: "cold-launch-profile", defaults: defaults, credentialStore: secureStore
        )
        settings.urlString = endpoint.absoluteString
        settings.isEnabled = false
        let previousPinning = IdentityPinningService(connectionID: settings.connectionID, secureStore: secureStore)
        try previousPinning.pin(evidence)
        previousPinning.storeEvidence(evidence, from: endpoint)
        let preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: evidence.instance.id)
        preferences.locationEnabled = true
        preferences.backgroundLocationEnabled = true
        preferences.visitsEnabled = true
        preferences.visitEnrichmentEnabled = true

        let now = Date()
        var visit = try #require(VisitSnapshot.make(
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -105),
            horizontalAccuracy: 10,
            arrivalDate: now.addingTimeInterval(-600),
            departureDate: now,
            capturedAt: now
        ))
        visit.placeContext = VisitPlaceContext(
            status: .resolved, provider: "cold-launch-test",
            address: VisitPlaceAddress(formatted: "123 Main Street")
        )
        let previousWindow = try VisitWindowStore(fileURL: windowURL).record(visit)
        let scope = ObservationDeliveryScope(connectionID: settings.connectionID, identityID: evidence.instance.id)
        self.scope = scope
        let previousOutbox = ObservationOutbox(fileURL: outboxURL)
        let deliveredVisit = try ObservationEvent.available(kind: .visits, observedAt: now, payload: previousWindow)
        let deliveredLocation = try ObservationEvent.available(
            kind: .location, observedAt: now,
            payload: LocationSnapshot(
                capturedAt: ObservationCoding.dateString(from: now),
                locationTimestamp: ObservationCoding.dateString(from: now),
                latitude: 40, longitude: -105, altitudeMeters: nil, ellipsoidalAltitudeMeters: nil,
                horizontalAccuracyMeters: 10, verticalAccuracyMeters: nil, speedMetersPerSecond: nil,
                speedAccuracyMetersPerSecond: nil, courseDegrees: nil, courseAccuracyDegrees: nil,
                floor: nil, authorization: "always", accuracyAuthorization: "full",
                simulatedBySoftware: false, producedByAccessory: false
            )
        )
        try await previousOutbox.enqueue(deliveredVisit, for: scope)
        try await previousOutbox.enqueue(deliveredLocation, for: scope)
        try await previousOutbox.removeSent([deliveredVisit.eventID, deliveredLocation.eventID], for: scope)
        #expect(try await previousOutbox.pending(for: scope).isEmpty)

        let outbox = ObservationOutbox(fileURL: outboxURL)
        self.outbox = outbox
        profile = AgentProfile(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            observationPublisher: ObservationPublisher(outbox: outbox, uploader: uploader),
            identityService: IdentityService(fetcher: fetcher),
            identityPinning: IdentityPinningService(connectionID: settings.connectionID, secureStore: secureStore),
            inboxStore: InboxStore(profileID: settings.profileID, storageDirectoryURL: directory),
            visitWindow: VisitWindowStore(fileURL: windowURL),
            locationManager: ColdLaunchLocationManager(authorization: authorization),
            visitPlaceResolver: resolver,
            locationAuthorizationSessionFactory: { ColdLaunchLocationSession() }
        )
    }

    func pending() async throws -> [ObservationEvent] {
        try await outbox.pending(for: scope)
    }

    func persistedPending() async throws -> [ObservationEvent] {
        try await ObservationOutbox(fileURL: outboxURL).pending(for: scope)
    }

    func cleanup() {
        profile.visitEnrichment.invalidate()
        profile.locationService.suspendForCounterpartyChange()
        profile.disconnect()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ColdLaunchLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    init(authorization: CLAuthorizationStatus) { authorizationStatus = authorization }
    func requestWhenInUseAuthorization() { Issue.record("Cold launch requested location permission") }
    func requestLocation() { Issue.record("Cold launch requested a live location") }
    func startMonitoringSignificantLocationChanges() { Issue.record("Cold launch started unauthorized monitoring") }
    func stopMonitoringSignificantLocationChanges() {}
    func startMonitoringVisits() { Issue.record("Cold launch started unauthorized visits") }
    func stopMonitoringVisits() {}
}

@MainActor
private final class ColdLaunchLocationSession: LocationAuthorizationSession {
    func invalidate() {}
}

@MainActor
private final class ColdLaunchPlaceResolver: VisitPlaceResolving {
    let provider = "cold-launch-test"
    private(set) var calls = 0
    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        calls += 1
        Issue.record("Cold launch looked up a visit after losing Always authorization")
        return VisitPlaceContext(status: .unavailable, provider: provider)
    }
}

@MainActor
private final class ColdLaunchIdentityFetcher: IdentityEvidenceFetching {
    private(set) var calls = 0
    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        calls += 1
        throw CancellationError()
    }
}

@MainActor
private final class ColdLaunchObservationUploader: ObservationUploading {
    private(set) var calls = 0
    func upload(_ batch: ObservationBatch, to baseURL: URL, token: String) async throws -> ObservationIngestResult {
        calls += 1
        return ObservationIngestResult(stored: batch.events.count, ignored: 0, receivedAt: Date())
    }
}

@MainActor
private final class ColdLaunchCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]
    func save(_ value: String, account: String) { values[account] = value }
    func load(account: String) -> String? { values[account] }
    func delete(account: String) { values[account] = nil }
}
