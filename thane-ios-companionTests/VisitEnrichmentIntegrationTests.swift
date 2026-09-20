import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit enrichment integration")
@MainActor
struct VisitEnrichmentIntegrationTests {
    @Test("A visit is stored and queued before its deferred lookup completes")
    func rawCapturePrecedesEnrichment() async throws {
        let fixture = try await VisitIntegrationFixture()
        defer { fixture.cleanup() }
        let visit = try fixture.makeVisit()
        fixture.profile.locationService.onVisit?(visit)

        let captured = try #require(fixture.profile.visitWindow.visit(id: visit.visitID))
        #expect(captured.placeContext == nil)
        let durable = VisitWindowStore(fileURL: fixture.windowURL)
        #expect(durable.visit(id: visit.visitID)?.capturedAt == visit.capturedAt)
        #expect(durable.visit(id: visit.visitID)?.placeContext == nil)

        try await waitUntil { fixture.resolver.hasPendingRequest }
        try await waitUntil { try await fixture.pendingWindow()?.visits.first?.visitID == visit.visitID }
        let raw = try #require(try await fixture.pendingWindow()?.visits.first)
        #expect(raw.placeContext == nil)
        #expect(fixture.resolver.hasPendingRequest)
        fixture.resolver.complete()
        try await waitUntil {
            try await fixture.pendingWindow()?.visits.first?.placeContext?.status == .resolved
        }
        let enriched = try #require(try await fixture.pendingWindow()?.visits.first)
        #expect(enriched.visitID == visit.visitID)
        #expect(enriched.capturedAt == visit.capturedAt)
        #expect(fixture.uploader.calls == 0)
    }

    @Test("A failed raw outbox write blocks lookup until a successful retry")
    func persistenceFailureBlocksLookup() async throws {
        let writer = RecoverableVisitWriter()
        let fixture = try await VisitIntegrationFixture(writer: writer)
        defer { fixture.cleanup() }
        let visit = try fixture.makeVisit()
        fixture.profile.locationService.onVisit?(visit)

        try await waitUntil { fixture.profile.visitEnrichment.lastError != nil }
        #expect(fixture.resolver.calls == 0)
        #expect(VisitWindowStore(fileURL: fixture.windowURL).visit(id: visit.visitID) != nil)
        #expect(try await fixture.pendingWindow() == nil)

        await writer.recover()
        fixture.profile.visitEnrichment.resume()
        try await waitUntil { fixture.resolver.hasPendingRequest }
        #expect(try await fixture.pendingWindow()?.visits.first?.visitID == visit.visitID)
        #expect(fixture.resolver.calls == 1)
        fixture.resolver.complete()
        try await waitUntil {
            try await fixture.pendingWindow()?.visits.first?.placeContext?.status == .resolved
        }
    }

    @Test("A departure during a lookup keeps one enriched settled visit")
    func departureMergesWithPendingLookup() async throws {
        let fixture = try await VisitIntegrationFixture()
        defer { fixture.cleanup() }
        let arrival = Date().addingTimeInterval(-600)
        let ongoing = try fixture.makeVisit(arrival: arrival, ongoing: true)
        fixture.profile.locationService.onVisit?(ongoing)
        try await waitUntil { fixture.resolver.hasPendingRequest }
        let settled = try fixture.makeVisit(arrival: arrival)
        fixture.profile.locationService.onVisit?(settled)
        fixture.resolver.complete()
        try await waitUntil {
            fixture.profile.visitWindow.visit(id: ongoing.visitID)?.placeContext?.status == .resolved
                && !fixture.profile.visitEnrichment.isResolving
        }

        let updated = try #require(fixture.profile.visitWindow.visit(id: ongoing.visitID))
        #expect(fixture.profile.visitWindow.window().visits.count == 1)
        #expect(updated.state == .settled)
        #expect(updated.departedAt == settled.departedAt)
        #expect(updated.capturedAt == settled.capturedAt)
        #expect(updated.dwellSeconds == settled.dwellSeconds)
        #expect(fixture.resolver.calls == 1)
        try await waitUntil {
            try await fixture.pendingWindow()?.visits.first?.placeContext?.status == .resolved
        }
        #expect(try await fixture.pendingWindow()?.visits.first?.state == .settled)
    }

    @Test("Opting out strips saved details and rejects a late lookup")
    func optOutRejectsLateResult() async throws {
        let fixture = try await VisitIntegrationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.makeVisit(arrival: Date().addingTimeInterval(-1_200))
        fixture.profile.locationService.onVisit?(first)
        try await waitUntil { fixture.resolver.hasPendingRequest }
        fixture.resolver.complete()
        try await waitUntil {
            fixture.profile.visitWindow.visit(id: first.visitID)?.placeContext?.status == .resolved
                && !fixture.profile.visitEnrichment.isResolving
        }
        let second = try fixture.makeVisit(arrival: Date().addingTimeInterval(-600))
        fixture.profile.locationService.onVisit?(second)
        try await waitUntil { fixture.resolver.hasPendingRequest }

        fixture.profile.setVisitEnrichment(enabled: false)
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.profile.visitWindow.window().visits.allSatisfy { $0.placeContext == nil })
        fixture.resolver.complete()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.profile.visitWindow.window().visits.count == 2)
        #expect(fixture.profile.visitWindow.window().visits.allSatisfy { $0.placeContext == nil })
        #expect(VisitWindowStore(fileURL: fixture.windowURL).window().visits.allSatisfy { $0.placeContext == nil })
        try await waitUntil {
            guard let window = try await fixture.pendingWindow() else { return false }
            return window.visits.count == 2 && window.visits.allSatisfy { $0.placeContext == nil }
        }
    }

    @Test("Revoking a parent prevents enrichment from restarting", arguments: ["location", "visits"])
    func parentRevocationDoesNotRearm(parent: String) async throws {
        let fixture = try await VisitIntegrationFixture()
        defer { fixture.cleanup() }
        let old = try fixture.makeVisit()
        fixture.profile.locationService.onVisit?(old)
        try await waitUntil { fixture.resolver.hasPendingRequest }

        if parent == "location" {
            fixture.profile.setLocationSharing(enabled: false)
        } else {
            fixture.profile.setVisitSharing(enabled: false)
        }
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.profile.visitWindow.isEmpty)
        fixture.profile.setLocationSharing(enabled: true)
        fixture.profile.setVisitSharing(enabled: true)
        fixture.resolver.complete()
        let later = try fixture.makeVisit(arrival: Date().addingTimeInterval(-120))
        fixture.profile.locationService.onVisit?(later)
        fixture.profile.visitEnrichment.resume()
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.resolver.calls == 1)
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.profile.visitWindow.visit(id: old.visitID) == nil)
        #expect(fixture.profile.visitWindow.visit(id: later.visitID)?.placeContext == nil)
    }

    @Test("A replacement counterparty cannot inherit an in-flight lookup")
    func counterpartyReplacementRejectsCompletion() async throws {
        let fixture = try await VisitIntegrationFixture()
        defer { fixture.cleanup() }
        let old = try fixture.makeVisit()
        fixture.profile.locationService.onVisit?(old)
        try await waitUntil { fixture.resolver.hasPendingRequest }
        let evidence = fixture.evidence
        let replacement = ThaneIdentityEvidence(
            schemaVersion: evidence.schemaVersion,
            observedAt: evidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:visit-replacement",
                name: "replacement",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519", fingerprint: "SHA256:visit-replacement"
                ),
                channelCA: evidence.instance.channelCA
            ),
            core: evidence.core
        )
        await fixture.profile.forgetThane()
        try #require(fixture.profile.configurationError == nil)
        fixture.profile.pin(replacement)
        try #require(fixture.profile.configurationError == nil)
        fixture.resolver.complete()
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.profile.sharingPreferences.counterpartyID == replacement.instance.id)
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.profile.visitWindow.isEmpty)
        #expect(VisitWindowStore(fileURL: fixture.windowURL).window().visits.isEmpty)
    }

    @Test("Losing Always authorization disarms enrichment and rejects the pending result")
    func authorizationLossDisarmsEnrichment() async throws {
        let fixture = try await VisitIntegrationFixture()
        defer { fixture.cleanup() }
        let old = try fixture.makeVisit()
        fixture.profile.locationService.onVisit?(old)
        try await waitUntil { fixture.resolver.hasPendingRequest }

        fixture.locationManager.authorizationStatus = .authorizedWhenInUse
        fixture.profile.locationService.locationManagerDidChangeAuthorization(CLLocationManager())
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.profile.visitWindow.isEmpty)
        #expect(fixture.profile.visitEnrichment.isResolving == false)
        fixture.resolver.complete()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.profile.visitWindow.isEmpty)
        #expect(VisitWindowStore(fileURL: fixture.windowURL).window().visits.isEmpty)

        fixture.locationManager.authorizationStatus = .authorizedAlways
        fixture.profile.locationService.locationManagerDidChangeAuthorization(CLLocationManager())
        fixture.profile.setLocationSharing(enabled: true)
        fixture.profile.setVisitSharing(enabled: true)
        let later = try fixture.makeVisit(arrival: Date().addingTimeInterval(-120))
        fixture.profile.locationService.onVisit?(later)
        fixture.profile.visitEnrichment.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.resolver.calls == 1)
        #expect(fixture.profile.sharingPreferences.visitEnrichmentEnabled == false)
        #expect(fixture.profile.visitWindow.visit(id: old.visitID) == nil)
        #expect(fixture.profile.visitWindow.visit(id: later.visitID)?.placeContext == nil)
    }

    private func waitUntil(_ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            if try await predicate() { return }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for visit integration")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class VisitIntegrationFixture {
    let profile: AgentProfile
    let evidence: ThaneIdentityEvidence
    let windowURL: URL
    let resolver = IntegrationVisitResolver()
    let uploader = IntegrationVisitUploader()
    let locationManager = IntegrationLocationManager()
    private let outbox: ObservationOutbox
    private let scope: ObservationDeliveryScope
    private let suite: String
    private let defaults: UserDefaults
    private let directory: URL

    init(writer: RecoverableVisitWriter? = nil) async throws {
        suite = "VisitEnrichmentIntegrationTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        windowURL = directory.appendingPathComponent("visits.json")
        evidence = try IdentityTestFixture.freshEvidence()
        let secureStore = IntegrationVisitSecureStore()
        let settings = ConnectionSettings(profileID: "visit-profile", defaults: defaults, credentialStore: secureStore)
        settings.urlString = "https://thane.example"
        settings.isEnabled = false
        let pinning = IdentityPinningService(connectionID: settings.connectionID, secureStore: secureStore)
        try pinning.pin(evidence)
        let scope = ObservationDeliveryScope(connectionID: settings.connectionID, identityID: evidence.instance.id)
        self.scope = scope
        let outbox = ObservationOutbox(fileURL: directory.appendingPathComponent("outbox.json"))
        self.outbox = outbox
        try await outbox.bind(to: scope)
        let enqueue: (@Sendable (ObservationEvent, ObservationDeliveryScope) async throws -> Bool)?
        if let writer {
            enqueue = { event, scope in try await writer.enqueue(event, for: scope, outbox: outbox) }
        } else {
            enqueue = nil
        }
        let publisher = ObservationPublisher(outbox: outbox, uploader: uploader, enqueueObservation: enqueue)
        profile = AgentProfile(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            observationPublisher: publisher,
            identityService: IdentityService(fetcher: IntegrationVisitIdentityFetcher()),
            identityPinning: pinning,
            inboxStore: InboxStore(profileID: settings.profileID, storageDirectoryURL: directory),
            visitWindow: VisitWindowStore(fileURL: windowURL),
            locationManager: locationManager,
            visitPlaceResolver: resolver,
            locationAuthorizationSessionFactory: { IntegrationLocationSession() }
        )
        profile.setLocationSharing(enabled: true)
        profile.setVisitSharing(enabled: true)
        profile.setVisitEnrichment(enabled: true)
    }

    func makeVisit(arrival: Date? = nil, ongoing: Bool = false) throws -> VisitSnapshot {
        let captured = Date()
        return try #require(VisitSnapshot.make(
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -105),
            horizontalAccuracy: 12,
            arrivalDate: arrival ?? captured.addingTimeInterval(-600),
            departureDate: ongoing ? .distantFuture : captured,
            capturedAt: captured
        ))
    }

    func pendingWindow() async throws -> VisitWindowSnapshot? {
        guard let event = try await outbox.pending(for: scope).first(where: { $0.kind == .visits }),
              event.status == .available, let payload = event.payload else { return nil }
        return try ObservationCoding.decoder().decode(
            VisitWindowSnapshot.self, from: JSONEncoder().encode(payload)
        )
    }

    func cleanup() {
        profile.visitEnrichment.invalidate()
        profile.locationService.suspendForCounterpartyChange()
        resolver.cancelAll()
        profile.disconnect()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RecoverableVisitWriter {
    private var shouldFail = true

    func recover() { shouldFail = false }

    func enqueue(
        _ event: ObservationEvent, for scope: ObservationDeliveryScope, outbox: ObservationOutbox
    ) async throws -> Bool {
        guard !shouldFail else { throw CocoaError(.fileWriteNoPermission) }
        return try await outbox.enqueue(event, for: scope)
    }
}

@MainActor
private final class IntegrationVisitResolver: VisitPlaceResolving {
    let provider = "integration"
    private(set) var calls = 0
    private var pending: [CheckedContinuation<VisitPlaceContext, any Error>] = []
    var hasPendingRequest: Bool { !pending.isEmpty }

    func resolve(_ visit: VisitSnapshot) async throws -> VisitPlaceContext {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func complete() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: VisitPlaceContext(
            status: .resolved, provider: provider,
            address: VisitPlaceAddress(formatted: "123 Main Street")
        ))
    }

    func cancelAll() {
        let continuations = pending
        pending = []
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class IntegrationLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    func requestWhenInUseAuthorization() { Issue.record("Unexpected location permission request") }
    func requestLocation() { Issue.record("Unexpected live location request") }
    func startMonitoringSignificantLocationChanges() {}
    func stopMonitoringSignificantLocationChanges() {}
    func startMonitoringVisits() {}
    func stopMonitoringVisits() {}
}

@MainActor
private final class IntegrationLocationSession: LocationAuthorizationSession {
    func invalidate() {}
}

@MainActor
private final class IntegrationVisitUploader: ObservationUploading {
    private(set) var calls = 0
    func upload(_ batch: ObservationBatch, to baseURL: URL, token: String) async throws -> ObservationIngestResult {
        calls += 1
        return ObservationIngestResult(stored: batch.events.count, ignored: 0, receivedAt: Date())
    }
}

@MainActor
private final class IntegrationVisitIdentityFetcher: IdentityEvidenceFetching {
    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        throw CancellationError()
    }
}

@MainActor
private final class IntegrationVisitSecureStore: CredentialStoring {
    private var values: [String: String] = [:]
    func save(_ value: String, account: String) { values[account] = value }
    func load(account: String) -> String? { values[account] }
    func delete(account: String) { values[account] = nil }
}
