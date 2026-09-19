import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Visit place details sharing")
@MainActor
struct VisitEnrichmentSharingTests {
    @Test("Place details stay off when location and visits are enabled")
    func requiresIndependentConsent() throws {
        let fixture = try EnrichmentSharingFixture()
        defer { fixture.cleanup() }
        let preferences = SharingPreferences(defaults: fixture.defaults)
        preferences.scope(to: "thane:one")
        #expect(preferences.visitEnrichmentEnabled == false)
        preferences.locationEnabled = true
        preferences.visitsEnabled = true
        #expect(preferences.visitEnrichmentEnabled == false)

        let restored = SharingPreferences(defaults: fixture.defaults)
        restored.scope(to: "thane:one")
        #expect(restored.locationEnabled)
        #expect(restored.visitsEnabled)
        #expect(restored.visitEnrichmentEnabled == false)
    }

    @Test("Place details persist for their counterparty without enabling background location")
    func consentIsScopedAndIndependent() throws {
        let fixture = try EnrichmentSharingFixture()
        defer { fixture.cleanup() }
        let preferences = SharingPreferences(defaults: fixture.defaults)
        preferences.scope(to: "thane:one")
        enableParents(preferences)
        preferences.visitEnrichmentEnabled = true
        #expect(preferences.backgroundLocationEnabled == false)

        preferences.scope(to: "thane:two")
        enableParents(preferences)
        #expect(preferences.visitEnrichmentEnabled == false)
        preferences.scope(to: "thane:one")
        #expect(preferences.visitEnrichmentEnabled)

        let restored = SharingPreferences(defaults: fixture.defaults)
        restored.scope(to: "thane:one")
        #expect(restored.visitEnrichmentEnabled)
        restored.scope(to: "thane:two")
        #expect(restored.visitEnrichmentEnabled == false)
    }

    @Test("Revoking either parent disarms place details permanently", arguments: ["location", "visits"])
    func parentRevocationDisarmsChild(parent: String) throws {
        let fixture = try EnrichmentSharingFixture()
        defer { fixture.cleanup() }
        let preferences = SharingPreferences(defaults: fixture.defaults)
        preferences.scope(to: "thane:one")
        enableParents(preferences)
        preferences.visitEnrichmentEnabled = true

        if parent == "location" {
            preferences.locationEnabled = false
        } else {
            preferences.visitsEnabled = false
        }
        #expect(preferences.visitEnrichmentEnabled == false)
        enableParents(preferences)
        #expect(preferences.visitEnrichmentEnabled == false)

        let restored = SharingPreferences(defaults: fixture.defaults)
        restored.scope(to: "thane:one")
        #expect(restored.visitEnrichmentEnabled == false)
    }

    @Test("Place details cannot be enabled without both parents", arguments: ["location", "visits", "both"])
    func unavailableParentsPreventOptIn(missing: String) throws {
        let fixture = try EnrichmentSharingFixture()
        defer { fixture.cleanup() }
        let preferences = SharingPreferences(defaults: fixture.defaults)
        preferences.scope(to: "thane:one")
        preferences.locationEnabled = missing == "visits"
        preferences.visitsEnabled = missing == "location"
        preferences.visitEnrichmentEnabled = true
        #expect(preferences.visitEnrichmentEnabled == false)
        enableParents(preferences)
        #expect(preferences.visitEnrichmentEnabled == false)
    }

    @Test("Restoring invalid child consent clears it from storage", arguments: ["location", "visits", "both"])
    func restoreDoesNotRearmInvalidConsent(missing: String) throws {
        let fixture = try EnrichmentSharingFixture()
        defer { fixture.cleanup() }
        let prefix = "sharing.counterparty.thane:one."
        fixture.defaults.set(missing == "visits", forKey: prefix + "location")
        fixture.defaults.set(missing == "location", forKey: prefix + "visits")
        fixture.defaults.set(true, forKey: prefix + "visit-enrichment")

        let preferences = SharingPreferences(defaults: fixture.defaults)
        preferences.scope(to: "thane:one")
        #expect(preferences.visitEnrichmentEnabled == false)
        #expect(fixture.defaults.bool(forKey: prefix + "visit-enrichment") == false)
        enableParents(preferences)
        preferences.scope(to: nil)
        preferences.scope(to: "thane:one")
        #expect(preferences.visitEnrichmentEnabled == false)
    }

    @Test("Removing a counterparty deletes only its place-detail consent")
    func removalClearsScopedConsent() throws {
        let fixture = try EnrichmentSharingFixture()
        defer { fixture.cleanup() }
        let preferences = SharingPreferences(defaults: fixture.defaults)
        for identity in ["thane:one", "thane:two"] {
            preferences.scope(to: identity)
            enableParents(preferences)
            preferences.visitEnrichmentEnabled = true
        }
        preferences.removeScope(for: "thane:two")
        #expect(preferences.counterpartyID == nil)
        #expect(preferences.visitEnrichmentEnabled == false)
        #expect(fixture.defaults.object(forKey: "sharing.counterparty.thane:two.visit-enrichment") == nil)
        preferences.scope(to: "thane:one")
        #expect(preferences.visitEnrichmentEnabled)
        preferences.scope(to: "thane:two")
        enableParents(preferences)
        #expect(preferences.visitEnrichmentEnabled == false)
    }

    private func enableParents(_ preferences: SharingPreferences) {
        preferences.locationEnabled = true
        preferences.visitsEnabled = true
    }
}

private struct EnrichmentSharingFixture {
    let suite: String
    let defaults: UserDefaults

    init() throws {
        suite = "VisitEnrichmentSharingTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}
