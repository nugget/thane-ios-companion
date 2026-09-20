import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit monitoring")
@MainActor
struct VisitMonitoringTests {
    private let ranch = CLLocationCoordinate2D(latitude: 29.8312, longitude: -98.4643)

    // MARK: - Snapshot boundaries

    /// CoreLocation signals a missed arrival with `.distantPast`. Passing it
    /// through is worse than useless: it predates the server's 2000-01-01
    /// floor, so as an event timestamp it 400s the whole batch and takes
    /// unrelated location and system-context events down with it.
    @Test("A missed arrival is reported as unknown, never as a timestamp")
    func missedArrivalIsHonest() throws {
        let departed = Date()
        let visit = try #require(VisitSnapshot.make(
            coordinate: ranch,
            horizontalAccuracy: 12,
            arrivalDate: .distantPast,
            departureDate: departed,
            capturedAt: departed
        ))

        #expect(visit.arrival == .unknown)
        #expect(visit.arrivedAt == nil)
        #expect(visit.dwellSeconds == nil)
        #expect(visit.state == .settled)
    }

    @Test("An ongoing visit has no departure and a partial dwell")
    func ongoingVisitIsMarked() throws {
        let arrived = Date().addingTimeInterval(-3600)
        let visit = try #require(VisitSnapshot.make(
            coordinate: ranch,
            horizontalAccuracy: 12,
            arrivalDate: arrived,
            departureDate: .distantFuture,
            capturedAt: arrived.addingTimeInterval(3600)
        ))

        #expect(visit.state == .ongoing)
        #expect(visit.departedAt == nil)
        #expect(visit.dwellIsPartial)
        #expect((visit.dwellSeconds ?? 0) >= 3599)
    }

    @Test("An invalid coordinate produces no visit")
    func invalidCoordinateRejected() {
        #expect(VisitSnapshot.make(
            coordinate: CLLocationCoordinate2D(latitude: 91, longitude: 0),
            horizontalAccuracy: 12,
            arrivalDate: Date(),
            departureDate: Date(),
            capturedAt: Date()
        ) == nil)
        #expect(VisitSnapshot.make(
            coordinate: ranch,
            horizontalAccuracy: -1,
            arrivalDate: Date(),
            departureDate: Date(),
            capturedAt: Date()
        ) == nil)
    }

    /// The event timestamp must be capture time, never an arrival. This is the
    /// assertion that keeps a missed arrival from rejecting the batch.
    @Test("The published window is timestamped after the server floor")
    func windowTimestampIsSane() throws {
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let window = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch,
            horizontalAccuracy: 9,
            arrivalDate: .distantPast,
            departureDate: .distantPast,
            capturedAt: Date()
        )))

        let observedAt = try #require(ObservationCoding.date(from: window.capturedAt))
        let floor = try #require(ISO8601DateFormatter().date(from: "2000-01-01T00:00:00Z"))
        #expect(observedAt > floor)
    }

    // MARK: - The window

    /// The outbox keeps one event per kind, so a one-visit-per-event design
    /// would silently drop the earlier of two visits settling between flushes.
    /// The window is re-sent whole for exactly this reason.
    @Test("The window keeps several visits and stays bounded")
    func windowAccumulatesAndBounds() throws {
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let base = Date()

        for i in 0..<(VisitWindowSnapshot.maxEntries + 4) {
            _ = try store.record(try #require(VisitSnapshot.make(
                coordinate: CLLocationCoordinate2D(latitude: 29.8 + Double(i) / 1000, longitude: -98.4),
                horizontalAccuracy: 10,
                arrivalDate: base.addingTimeInterval(Double(i) * 60 - 3600),
                departureDate: base.addingTimeInterval(Double(i) * 60),
                capturedAt: base
            )), now: base)
        }

        let window = store.window(now: base)
        #expect(window.visits.count == VisitWindowSnapshot.maxEntries)
        #expect(window.returnedCount == VisitWindowSnapshot.maxEntries)
        #expect(window.visits.first?.anchorDate ?? .distantPast
            > window.visits.last?.anchorDate ?? .distantFuture)
    }

    @Test("A settled visit replaces its ongoing self rather than duplicating")
    func settledReplacesOngoing() throws {
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let arrived = Date().addingTimeInterval(-1800)

        _ = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch, horizontalAccuracy: 10,
            arrivalDate: arrived, departureDate: .distantFuture, capturedAt: Date()
        )))
        let window = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch, horizontalAccuracy: 10,
            arrivalDate: arrived, departureDate: Date(), capturedAt: Date()
        )))

        #expect(window.visits.count == 1)
        #expect(window.visits.first?.state == .settled)
    }

    @Test("The window survives a relaunch")
    func windowPersists() throws {
        let url = Self.tempFile()
        let first = VisitWindowStore(fileURL: url)
        _ = try first.record(try #require(VisitSnapshot.make(
            coordinate: ranch, horizontalAccuracy: 10,
            arrivalDate: Date().addingTimeInterval(-600), departureDate: Date(), capturedAt: Date()
        )))

        let relaunched = VisitWindowStore(fileURL: url)
        defer { relaunched.discardAll() }
        #expect(relaunched.window().visits.count == 1)
    }

    @Test("Discarding leaves nothing to republish")
    func discardClearsTheWindow() throws {
        let url = Self.tempFile()
        let store = VisitWindowStore(fileURL: url)
        _ = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch, horizontalAccuracy: 10,
            arrivalDate: Date().addingTimeInterval(-600), departureDate: Date(), capturedAt: Date()
        )))
        store.discardAll()

        #expect(store.isEmpty)
        #expect(VisitWindowStore(fileURL: url).window().visits.isEmpty)
    }

    // MARK: - Review findings

    /// An ongoing stay that began days ago is current, not stale. Anchoring it
    /// to its arrival pruned it on sight.
    @Test("A long ongoing visit is not pruned as stale")
    func longOngoingVisitSurvives() throws {
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let now = Date()
        let window = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch,
            horizontalAccuracy: 10,
            arrivalDate: now.addingTimeInterval(-72 * 3600),
            departureDate: .distantFuture,
            capturedAt: now
        )), now: now)

        #expect(window.visits.count == 1)
        #expect(window.visits.first?.state == .ongoing)
    }

    /// Every missed arrival is nil, so keying replacement on it folded
    /// unrelated visits into one.
    @Test("Missed-arrival visits at one place do not collapse together")
    func missedArrivalsDoNotCollide() throws {
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let now = Date()

        for offset in [-3600.0, -1800.0] {
            _ = try store.record(try #require(VisitSnapshot.make(
                coordinate: ranch,
                horizontalAccuracy: 10,
                arrivalDate: .distantPast,
                departureDate: now.addingTimeInterval(offset),
                capturedAt: now.addingTimeInterval(offset)
            )), now: now)
        }

        #expect(store.window(now: now).visits.count == 2)
    }

    /// Pruning ran only on write, so a file loaded at launch — or a quiet
    /// 48 hours — returned entries older than the advertised window.
    @Test("The window applies its cutoff on read, not only on write")
    func windowCutoffAppliesOnRead() throws {
        let url = Self.tempFile()
        let store = VisitWindowStore(fileURL: url)
        let recorded = Date()
        _ = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch, horizontalAccuracy: 10,
            arrivalDate: recorded.addingTimeInterval(-600),
            departureDate: recorded, capturedAt: recorded
        )), now: recorded)

        let relaunched = VisitWindowStore(fileURL: url)
        defer { relaunched.discardAll() }
        let muchLater = recorded.addingTimeInterval(VisitWindowSnapshot.windowHours * 3600 + 60)

        #expect(relaunched.window(now: muchLater).visits.isEmpty)
    }

    /// The cap trims before the window is built, so deriving truncation at
    /// read time reported false however much had been dropped.
    @Test("Dropping a visit to the cap is reported as truncated")
    func truncationIsReported() throws {
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let now = Date()

        for i in 0...VisitWindowSnapshot.maxEntries {
            _ = try store.record(try #require(VisitSnapshot.make(
                coordinate: CLLocationCoordinate2D(latitude: 29.8 + Double(i) / 1000, longitude: -98.4),
                horizontalAccuracy: 10,
                arrivalDate: now.addingTimeInterval(Double(i) * 60 - 3600),
                departureDate: now.addingTimeInterval(Double(i) * 60),
                capturedAt: now
            )), now: now)
        }

        let window = store.window(now: now)
        #expect(window.visits.count == VisitWindowSnapshot.maxEntries)
        #expect(window.truncated)
    }

    @Test("Discarding removes the file, so a relaunch loads nothing")
    func discardRemovesTheFile() throws {
        let url = Self.tempFile()
        let store = VisitWindowStore(fileURL: url)
        _ = try store.record(try #require(VisitSnapshot.make(
            coordinate: ranch, horizontalAccuracy: 10,
            arrivalDate: Date().addingTimeInterval(-600), departureDate: Date(), capturedAt: Date()
        )))

        #expect(store.discardAll())
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(VisitWindowStore(fileURL: url).window().visits.isEmpty)
    }

    /// Authorization changes reconciled only for significant changes, so a
    /// visits-only operator granting Always started nothing.
    @Test("An Always upgrade starts visits with background location off")
    func alwaysUpgradeStartsVisitsOnly() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        fixture.preferences.locationEnabled = true
        fixture.preferences.backgroundLocationEnabled = false
        fixture.preferences.visitsEnabled = true

        manager.authorizationStatus = .authorizedAlways
        service.locationManagerDidChangeAuthorization(CLLocationManager())

        #expect(service.isVisitMonitoringActive)
        #expect(manager.startVisitsCount >= 1)
    }

    /// Stopping delivery is not withdrawal: without the callback the server
    /// kept serving the last visit and the window stayed on disk.
    @Test("Revoking Location asks for visit withdrawal")
    func revocationRequestsWithdrawal() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        var withdrawals = 0
        service.onVisitMonitoringUnavailable = { withdrawals += 1 }

        fixture.preferences.locationEnabled = true
        service.setVisitMonitoringEnabled(true)
        fixture.preferences.locationEnabled = false
        service.cancelPendingRequestAfterConsentRevocation()

        #expect(withdrawals == 1)
    }

    // MARK: - Second review pass

    /// `visitsEnabled` stays true through an OS downgrade — the operator did
    /// not revoke, iOS did — so consent alone is not enough to accept a
    /// callback queued before the downgrade.
    @Test("A visit delivered after an authorization downgrade is refused")
    func lateVisitAfterDowngradeIsRefused() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        var delivered = 0
        service.onVisit = { _ in delivered += 1 }

        fixture.preferences.locationEnabled = true
        service.setVisitMonitoringEnabled(true)

        manager.authorizationStatus = .authorizedWhenInUse
        service.locationManager(CLLocationManager(), didVisit: StubVisit())

        #expect(delivered == 0)
        #expect(manager.stopVisitsCount >= 1)
    }

    /// Turning Background Location off must not revoke Always out from under
    /// visits. Third instance of the shared-session mistake, in the last path
    /// that still had it.
    @Test("Turning background location off keeps the session for visits")
    func backgroundOffKeepsSessionForVisits() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let session = FakeAuthorizationSession()
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            authorizationSessionFactory: { session }
        )

        fixture.preferences.locationEnabled = true
        service.setVisitMonitoringEnabled(true)
        service.setBackgroundMonitoringEnabled(true)

        service.setBackgroundMonitoringEnabled(false)

        #expect(service.isVisitMonitoringActive)
        #expect(session.invalidateCount == 0)
    }

    /// Truncation has to survive a relaunch and expire with the window it
    /// describes: a flag did neither.
    @Test("Truncation survives a relaunch and ages out with the window")
    func truncationIsDurableAndExpires() throws {
        let url = Self.tempFile()
        let now = Date()
        let store = VisitWindowStore(fileURL: url)
        for i in 0...VisitWindowSnapshot.maxEntries {
            _ = try store.record(try #require(VisitSnapshot.make(
                coordinate: CLLocationCoordinate2D(latitude: 29.8 + Double(i) / 1000, longitude: -98.4),
                horizontalAccuracy: 10,
                arrivalDate: now.addingTimeInterval(Double(i) * 60 - 3600),
                departureDate: now.addingTimeInterval(Double(i) * 60),
                capturedAt: now
            )), now: now)
        }

        let relaunched = VisitWindowStore(fileURL: url)
        defer { relaunched.discardAll() }
        #expect(relaunched.window(now: now).truncated)

        let afterWindow = now.addingTimeInterval(VisitWindowSnapshot.windowHours * 3600 + 60)
        #expect(relaunched.window(now: afterWindow).truncated == false)
    }

    // MARK: - Consent and the shared Always session

    /// Visit monitoring is process-wide and, per the SDK, continues "even
    /// across application relaunch events". A restore that finds it disabled
    /// must actively send stopMonitoringVisits; merely returning leaves the
    /// system delivering visits the operator switched off.
    @Test("A launch with visits disabled stops monitoring rather than returning")
    func disabledLaunchStopsMonitoring() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        service.restoreBackgroundMonitoringIfAuthorized()

        #expect(manager.stopVisitsCount >= 1)
        #expect(manager.startVisitsCount == 0)
    }

    /// The Always session is shared with significant-change monitoring. Keying
    /// its teardown to background location alone tore it down for visits.
    @Test("Visits keep the Always session with background location off")
    func visitsHoldTheSharedSession() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let session = FakeAuthorizationSession()
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            authorizationSessionFactory: { session }
        )

        fixture.preferences.locationEnabled = true
        fixture.preferences.backgroundLocationEnabled = false
        fixture.preferences.visitsEnabled = true
        service.restoreBackgroundMonitoringIfAuthorized()

        #expect(service.isVisitMonitoringActive)
        #expect(manager.startVisitsCount >= 1)
        #expect(manager.startSignificantCount == 0)
        // The point of the test: with significant changes off, the session is
        // held by visits alone and must not be invalidated. Asserting only the
        // monitoring flags left the session lifetime untested.
        #expect(session.invalidateCount == 0)
    }

    /// Revoking the parent must disarm the child, or re-enabling Location
    /// later resumes visits silently — bundled consent through the back door.
    @Test("Revoking Location disarms visits")
    func revokingLocationDisarmsVisits() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        fixture.preferences.locationEnabled = true
        fixture.preferences.visitsEnabled = true
        service.restoreBackgroundMonitoringIfAuthorized()
        #expect(service.isVisitMonitoringActive)

        fixture.preferences.locationEnabled = false
        service.cancelPendingRequestAfterConsentRevocation()

        #expect(fixture.preferences.visitsEnabled == false)
        #expect(service.isVisitMonitoringActive == false)
    }

    /// The toggle is the whole point of an independent category: turning it
    /// off must stop the system delivering visits, not merely stop publishing
    /// them, because monitoring is process-wide and outlives the app.
    @Test("Turning Visit History off stops monitoring and releases the session")
    func togglingOffStopsMonitoring() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let session = FakeAuthorizationSession()
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            authorizationSessionFactory: { session }
        )

        fixture.preferences.locationEnabled = true
        service.setVisitMonitoringEnabled(true)
        #expect(service.isVisitMonitoringActive)

        service.setVisitMonitoringEnabled(false)

        #expect(service.isVisitMonitoringActive == false)
        #expect(manager.stopVisitsCount >= 1)
        #expect(fixture.preferences.visitsEnabled == false)
        // Nothing else wanted Always, so the session goes with it.
        #expect(session.invalidateCount == 1)
    }

    /// Enabling visits without the parent must not arm anything.
    @Test("Visit History cannot be enabled without Location")
    func togglingRequiresLocation() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        fixture.preferences.locationEnabled = false
        service.setVisitMonitoringEnabled(true)

        #expect(fixture.preferences.visitsEnabled == false)
        #expect(service.isVisitMonitoringActive == false)
        #expect(manager.startVisitsCount == 0)
    }

    /// A visit can arrive "possibly from a prior launch", so consent is
    /// re-checked at delivery rather than assumed from whatever armed it.
    @Test("The tool refuses when visit sharing is off")
    func toolRefusesWhenDisabled() async throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let store = VisitWindowStore(fileURL: Self.tempFile())
        defer { store.discardAll() }
        let handler = VisitsPlatformHandler(store: store, preferences: fixture.preferences)

        await #expect(throws: VisitsHandlerError.self) {
            _ = try await handler.handle(method: "get_recent_visits", params: [:])
        }

        fixture.preferences.locationEnabled = true
        fixture.preferences.visitsEnabled = true
        let answered = try await handler.handle(method: "get_recent_visits", params: [:])
        #expect(answered.value is [String: Any])
    }

    private static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("visits-\(UUID().uuidString).json")
    }
}


/// `CLVisit` has no public initialiser, so a delegate-level test needs a
/// subclass overriding the four values it carries.
private final class StubVisit: CLVisit {
    override var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 29.8312, longitude: -98.4643)
    }
    override var horizontalAccuracy: CLLocationAccuracy { 10 }
    override var arrivalDate: Date { Date().addingTimeInterval(-3600) }
    override var departureDate: Date { Date() }
}
