import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("App preferences")
@MainActor
struct AppPreferencesTests {
    @Test("Appearance defaults to the system setting")
    func defaultAppearance() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.appearance == .automatic)
    }

    @Test("Appearance persists independently of agent configuration")
    func appearancePersistence() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = .dark

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.appearance == .dark)
    }

    @Test("Unknown stored appearances fail back to automatic")
    func unknownAppearance() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-value", forKey: "app.appearance")

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.appearance == .automatic)
    }

    @Test("Image context defaults off independently of photo sharing")
    func visualContextDefaultOff() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sharing.photos")

        #expect(!AppPreferences(defaults: defaults).visualContextEnabled)
    }

    @Test("Image context opt-in persists and can be revoked")
    func visualContextPersistence() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.visualContextEnabled = true

        #expect(AppPreferences(defaults: defaults).visualContextEnabled)
        preferences.visualContextEnabled = false
        #expect(!AppPreferences(defaults: defaults).visualContextEnabled)
    }

}
