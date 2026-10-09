import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Connection settings")
@MainActor
struct ConnectionSettingsTests {
    @Test("Pairwise client identity is durable, counterparty-bound, and rotated on rebind")
    func pairwiseClientIdentity() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }

        let settings = fixture.settings(profileID: "profile-one")
        let connectionID = settings.connectionID
        let clientID = settings.pairwiseClientID

        #expect(!settings.bindPairwiseClientID(to: "thane:identity:first"))
        #expect(settings.pairwiseClientID == clientID)

        let restored = fixture.settings(profileID: "profile-one")
        #expect(restored.profileID == "profile-one")
        #expect(restored.connectionID == connectionID)
        #expect(restored.pairwiseClientID == clientID)
        #expect(restored.pairwiseCounterpartyID == "thane:identity:first")
        #expect(!restored.bindPairwiseClientID(to: "thane:identity:first"))

        #expect(restored.bindPairwiseClientID(to: "thane:identity:second"))
        #expect(restored.connectionID == connectionID)
        #expect(restored.pairwiseClientID != clientID)
        #expect(restored.pairwiseCounterpartyID == "thane:identity:second")
    }

    @Test("Two profiles sharing one defaults suite never collide")
    func twoProfilesInOneSuiteAreIndependent() throws {
        // The production app has exactly one UserDefaults suite. Proving
        // independence therefore requires one suite and two profile IDs; an
        // earlier version of this test used two suites and could not have
        // caught profiles resolving the same connection ID.
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }

        let first = fixture.settings(profileID: "profile-one")
        let second = fixture.settings(profileID: "profile-two")

        first.urlString = "https://first.example"
        second.urlString = "https://second.example"
        first.isEnabled = true
        second.isEnabled = false
        first.bindPairwiseClientID(to: "thane:identity:first")
        second.bindPairwiseClientID(to: "thane:identity:second")
        try first.saveToken("first-token")
        try second.saveToken("second-token")

        #expect(first.connectionID != second.connectionID)
        #expect(first.pairwiseClientID != second.pairwiseClientID)
        #expect(first.securityScope.tokenAccount != second.securityScope.tokenAccount)
        #expect(
            fixture.credentials.value(account: first.securityScope.tokenAccount) == "first-token"
        )
        #expect(
            fixture.credentials.value(account: second.securityScope.tokenAccount) == "second-token"
        )

        let restoredFirst = fixture.settings(profileID: "profile-one")
        let restoredSecond = fixture.settings(profileID: "profile-two")
        #expect(restoredFirst.urlString == "https://first.example")
        #expect(restoredSecond.urlString == "https://second.example")
        #expect(restoredFirst.isEnabled)
        #expect(restoredSecond.isEnabled == false)
        #expect(restoredFirst.connectionID == first.connectionID)
        #expect(restoredSecond.connectionID == second.connectionID)
    }

    @Test("Removing configuration preserves the profile and rotates connection identities")
    func removalRotatesIdentities() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings(profileID: "profile-one")
        settings.bindPairwiseClientID(to: "thane:identity:first")
        let connectionID = settings.connectionID
        let clientID = settings.pairwiseClientID

        settings.removeConfiguration()

        #expect(settings.profileID == "profile-one")
        #expect(settings.connectionID != connectionID)
        #expect(settings.pairwiseClientID != clientID)
        #expect(settings.pairwiseCounterpartyID == nil)
    }

    @Test("Profile-scoped keys use the documented literals")
    func scopedKeysUseDocumentedLiterals() throws {
        // These key strings are hashed into durable storage paths and Keychain
        // account names. Renaming one silently orphans user data, and every
        // other test in this file round-trips through the same accessor, so it
        // would pass regardless. Pin the literals.
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }

        let settings = fixture.settings(profileID: "profile-one")
        settings.urlString = "https://thane.example"
        settings.isEnabled = true

        #expect(fixture.defaults.string(forKey: "agent.profile-one.baseURL") == "https://thane.example")
        #expect(fixture.defaults.bool(forKey: "agent.profile-one.enabled"))
        #expect(
            fixture.defaults.string(forKey: "agent.profile-one.configurationID")
                == settings.connectionID
        )
        #expect(fixture.defaults.string(forKey: "agent.profile-one.profileID") == "profile-one")
        #expect(
            fixture.defaults.string(
                forKey: "connection.pairwiseClientID.\(settings.connectionID)"
            ) == settings.pairwiseClientID
        )

        // Nothing may be written back to the pre-scoping global names.
        #expect(fixture.defaults.object(forKey: "connection.baseURL") == nil)
        #expect(fixture.defaults.object(forKey: "connection.enabled") == nil)
    }

    @Test("A pre-scoping installation keeps its profile and connection identity")
    func preScopingInstallationIsAdoptedInPlace() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        fixture.defaults.set("profile-one", forKey: "connection.profileID")
        fixture.defaults.set("https://legacy.example", forKey: "connection.baseURL")
        fixture.defaults.set(true, forKey: "connection.enabled")

        let profileIDs = AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)

        // The profile ID is SHA-256 hashed into the inbox and outbox paths, so
        // adopting the existing value verbatim is what keeps that data reachable.
        #expect(profileIDs == ["profile-one"])

        let settings = fixture.settings(profileID: "profile-one")
        #expect(settings.connectionID == "connection-one")
        #expect(settings.urlString == "https://legacy.example")
        #expect(settings.isEnabled)

        // Identity-bearing legacy keys are retained as the recovery anchor;
        // consumed non-identity keys are removed.
        #expect(fixture.defaults.string(forKey: "connection.profileID") == "profile-one")
        #expect(fixture.defaults.string(forKey: "connection.configurationID") == "connection-one")
        #expect(fixture.defaults.object(forKey: "connection.baseURL") == nil)
        #expect(fixture.defaults.object(forKey: "connection.enabled") == nil)
    }

    @Test("A pre-scoping installation without a profile ID adopts its connection ID")
    func preScopingInstallationWithoutProfileIDAdoptsConnectionID() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")

        #expect(AgentProfileRoster.resolveProfileIDs(in: fixture.defaults) == ["connection-one"])
        #expect(fixture.settings(profileID: "connection-one").connectionID == "connection-one")
    }

    @Test("Adoption is idempotent across repeated launches")
    func adoptionIsIdempotent() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        fixture.defaults.set("profile-one", forKey: "connection.profileID")

        let first = AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)
        let second = AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)
        let third = AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)

        #expect(first == ["profile-one"])
        #expect(second == first)
        #expect(third == first)
    }

    @Test("A lost roster rebuilds from profile anchors instead of minting new identities")
    func lostRosterRebuildsFromAnchors() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        _ = fixture.settings(profileID: "profile-one")
        _ = fixture.settings(profileID: "profile-two")
        fixture.defaults.set(["profile-one", "profile-two"], forKey: AgentProfileRoster.rosterKey)
        fixture.defaults.set(true, forKey: AgentProfileRoster.scopingMigrationKey)

        // Losing the roster array must not mint a fresh ID over storage that is
        // still on disk under the old one.
        fixture.defaults.removeObject(forKey: AgentProfileRoster.rosterKey)

        #expect(
            AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)
                == ["profile-one", "profile-two"]
        )
    }

    @Test("An interrupted adoption re-derives identical identities on the next launch")
    func interruptedAdoptionIsRecoverable() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        fixture.defaults.set("profile-one", forKey: "connection.profileID")

        // Simulate a process death partway through adoption: some scoped values
        // landed, but the anchor and roster never did. Recovery must re-run
        // adoption rather than treating the profile as already migrated.
        fixture.defaults.set("https://thane.example", forKey: "agent.profile-one.baseURL")

        let profileIDs = AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)

        #expect(profileIDs == ["profile-one"])
        #expect(fixture.settings(profileID: "profile-one").connectionID == "connection-one")
    }

    @Test("An anchor is never written before the connection identity it vouches for")
    func anchorIsWrittenAfterConnectionIdentity() throws {
        // A completed adoption looks identical whichever order these land in, so
        // asserting the end state cannot catch this. The defect lives entirely in
        // the crash window: an anchor visible first ends recovery early on the
        // next launch, a fresh connection ID is minted, and the existing token
        // and identity pin become unreachable. Observe the write order directly.
        let suite = "ConnectionSettingsTests.order.\(UUID().uuidString)"
        let defaults = try #require(OrderRecordingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("connection-one", forKey: "connection.configurationID")
        defaults.set("profile-one", forKey: "connection.profileID")
        defaults.removeAllRecordedWrites()

        _ = AgentProfileRoster.resolveProfileIDs(in: defaults)

        let anchor = defaults.recordedWrites.firstIndex(of: "agent.profile-one.profileID")
        let connection = defaults.recordedWrites.firstIndex(of: "agent.profile-one.configurationID")
        let anchorIndex = try #require(anchor)
        let connectionIndex = try #require(connection)
        #expect(connectionIndex < anchorIndex)
    }

    @Test("A non-owner profile never deletes the unmigrated legacy token")
    func nonOwnerLeavesLegacyTokenIntact() throws {
        let credentials = FakeCredentialStore(
            values: [ConnectionSecurityScope.legacyTokenAccount: "secret"]
        )
        let fixture = try SettingsFixture(credentials: credentials)
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        #expect(AgentProfileRoster.resolveProfileIDs(in: fixture.defaults) == ["connection-one"])
        _ = AgentProfileRoster.appendProfileID(in: fixture.defaults)

        // A non-owner that already holds its own scoped token still reaches the
        // early-return branch of storedToken(); that branch must not consume the
        // legacy account belonging to the profile that has yet to migrate.
        let other = fixture.settings(profileID: "profile-two")
        try other.saveToken("other-token")
        #expect(try other.storedToken() == "other-token")
        #expect(credentials.value(account: ConnectionSecurityScope.legacyTokenAccount) == "secret")

        let owner = fixture.settings(profileID: "connection-one")
        #expect(try owner.storedToken() == "secret")
    }

    @Test("Legacy client identity and token migrate into the adopting profile only")
    func legacyMigration() throws {
        let credentials = FakeCredentialStore(
            values: [ConnectionSecurityScope.legacyTokenAccount: "secret"]
        )
        let fixture = try SettingsFixture(credentials: credentials)
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        fixture.defaults.set("legacy-client", forKey: "connection.clientID")

        let profileIDs = AgentProfileRoster.resolveProfileIDs(in: fixture.defaults)
        #expect(profileIDs == ["connection-one"])

        let settings = fixture.settings(profileID: "connection-one")
        #expect(settings.connectionID == "connection-one")
        #expect(settings.pairwiseClientID == "legacy-client")
        #expect(try settings.storedToken() == "secret")
        #expect(credentials.value(account: settings.securityScope.tokenAccount) == "secret")
        #expect(credentials.value(account: ConnectionSecurityScope.legacyTokenAccount) == nil)
        #expect(fixture.defaults.object(forKey: "connection.clientID") == nil)

        let restored = fixture.settings(profileID: "connection-one")
        #expect(restored.pairwiseClientID == "legacy-client")
    }

    @Test("A second profile never adopts another profile's legacy identity")
    func legacyAdoptionIsSingleOwner() throws {
        let credentials = FakeCredentialStore(
            values: [ConnectionSecurityScope.legacyTokenAccount: "secret"]
        )
        let fixture = try SettingsFixture(credentials: credentials)
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        fixture.defaults.set("legacy-client", forKey: "connection.clientID")
        // Adoption places the inheriting profile at roster position 0, which is
        // what makes it the sole claimant of the unscoped legacy values.
        #expect(AgentProfileRoster.resolveProfileIDs(in: fixture.defaults) == ["connection-one"])
        _ = AgentProfileRoster.appendProfileID(in: fixture.defaults)

        // A profile that did not inherit the pre-scoping installation must not
        // claim its unscoped client ID or Keychain token.
        let other = fixture.settings(profileID: "profile-two")
        #expect(other.pairwiseClientID != "legacy-client")
        #expect(try other.storedToken() == nil)
        #expect(credentials.value(account: ConnectionSecurityScope.legacyTokenAccount) == "secret")
        #expect(fixture.defaults.string(forKey: "connection.clientID") == "legacy-client")

        // The rightful owner still gets them afterwards.
        let owner = fixture.settings(profileID: "connection-one")
        #expect(owner.pairwiseClientID == "legacy-client")
        #expect(try owner.storedToken() == "secret")
    }

    @Test("Purging a profile removes its scoped and pairwise values")
    func purgeRemovesScopedValues() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings(profileID: "profile-one")
        settings.urlString = "https://thane.example"
        settings.bindPairwiseClientID(to: "thane:identity:first")
        let connectionID = settings.connectionID

        ConnectionSettings.purgeScopedValues(profileID: "profile-one", in: fixture.defaults)

        #expect(fixture.defaults.object(forKey: "agent.profile-one.baseURL") == nil)
        #expect(fixture.defaults.object(forKey: "agent.profile-one.enabled") == nil)
        #expect(fixture.defaults.object(forKey: "agent.profile-one.configurationID") == nil)
        #expect(fixture.defaults.object(forKey: "agent.profile-one.profileID") == nil)
        #expect(
            fixture.defaults.object(forKey: "connection.pairwiseClientID.\(connectionID)") == nil
        )
        #expect(
            fixture.defaults.object(
                forKey: "connection.pairwiseCounterpartyID.\(connectionID)"
            ) == nil
        )
    }

    @Test("Forget Token deletes the connection-scoped Keychain value, clears the field, and disconnects")
    func forgetToken() throws {
        let credentials = FakeCredentialStore(
            values: [ConnectionSecurityScope.legacyTokenAccount: "secret"]
        )
        let fixture = try SettingsFixture(credentials: credentials)
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        let settings = fixture.settings(profileID: "connection-one")
        settings.isEnabled = true
        let preferences = SharingPreferences(defaults: fixture.defaults)
        let profile = AgentProfile(
            connectionSettings: settings,
            sharingPreferences: preferences,
            identityPinning: IdentityPinningService(
                connectionID: settings.connectionID,
                secureStore: FakeCredentialStore()
            )
        )

        #expect(profile.tokenInput == "secret")
        #expect(credentials.value(account: settings.securityScope.tokenAccount) == "secret")

        profile.forgetToken()

        #expect(credentials.value(account: settings.securityScope.tokenAccount) == nil)
        #expect(credentials.value(account: ConnectionSecurityScope.legacyTokenAccount) == nil)
        #expect(profile.tokenInput.isEmpty)
        #expect(settings.isEnabled == false)
        #expect(profile.connection.state == .disconnected)
    }
}

@MainActor
private final class FakeCredentialStore: CredentialStoring {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
    }

    func value(account: String) -> String? {
        values[account]
    }
}

/// Records the order of key writes so ordering invariants that only matter in a
/// crash window can be asserted without actually interrupting the process.
private final class OrderRecordingDefaults: UserDefaults {
    private(set) var recordedWrites: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        recordedWrites.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    func removeAllRecordedWrites() {
        recordedWrites.removeAll()
    }
}

@MainActor
private final class SettingsFixture {
    let suite: String
    let defaults: UserDefaults
    let credentials: FakeCredentialStore

    init(credentials: FakeCredentialStore = FakeCredentialStore()) throws {
        suite = "ConnectionSettingsTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        self.credentials = credentials
    }

    func settings(profileID: String) -> ConnectionSettings {
        ConnectionSettings(
            profileID: profileID,
            defaults: defaults,
            credentialStore: credentials
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}
