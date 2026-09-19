import Foundation

nonisolated enum SystemContextCategory: String, CaseIterable, Identifiable, Sendable {
    case regional
    case device
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regional: "Time & Region"
        case .device: "Device State"
        case .network: "Network State"
        }
    }

    var detail: String {
        switch self {
        case .regional:
            "Current time, time zone, locale, languages, calendar, and hour format."
        case .device:
            "Device class, OS version, battery, Low Power Mode, and thermal state."
        case .network:
            "Connectivity, interface types, address-family support, and constrained or expensive status."
        }
    }
}

@Observable
@MainActor
final class SharingPreferences {
    private nonisolated static let legacyKeyPrefix = "sharing."
    private nonisolated static let scopedKeyPrefix = "sharing.counterparty."
    private nonisolated static let migrationKey = "sharing.scoped-migration-complete"
    private let defaults: UserDefaults
    private var isLoadingScope = false
    private var storedVisitEnrichmentEnabled: Bool

    private(set) var counterpartyID: String?

    var regionalEnabled: Bool {
        didSet { persist(regionalEnabled, key: SystemContextCategory.regional.rawValue) }
    }
    var deviceEnabled: Bool {
        didSet { persist(deviceEnabled, key: SystemContextCategory.device.rawValue) }
    }
    var networkEnabled: Bool {
        didSet { persist(networkEnabled, key: SystemContextCategory.network.rawValue) }
    }
    var locationEnabled: Bool {
        didSet {
            persist(locationEnabled, key: "location")
            if !locationEnabled { visitEnrichmentEnabled = false }
        }
    }
    var backgroundLocationEnabled: Bool {
        didSet { persist(backgroundLocationEnabled, key: "background-location") }
    }
    var photosEnabled: Bool {
        didSet { persist(photosEnabled, key: "photos") }
    }
    /// Visit monitoring: places the operator lingered, with arrival and
    /// departure times. Its own category rather than a rider on background
    /// location — agreeing to publish a position when the phone moves is not
    /// agreeing to a record of where time is spent, and bundling the two would
    /// be exactly the consent AGENTS.md forbids.
    var visitsEnabled: Bool {
        didSet {
            persist(visitsEnabled, key: "visits")
            if !visitsEnabled { visitEnrichmentEnabled = false }
        }
    }
    var visitEnrichmentEnabled: Bool {
        get { storedVisitEnrichmentEnabled && locationEnabled && visitsEnabled }
        set {
            storedVisitEnrichmentEnabled = newValue && locationEnabled && visitsEnabled
            persist(storedVisitEnrichmentEnabled, key: "visit-enrichment")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        counterpartyID = nil
        regionalEnabled = false
        deviceEnabled = false
        networkEnabled = false
        locationEnabled = false
        backgroundLocationEnabled = false
        photosEnabled = false
        visitsEnabled = false
        storedVisitEnrichmentEnabled = false
    }

    var enabledSystemCategories: Set<SystemContextCategory> {
        Set(SystemContextCategory.allCases.filter(isEnabled))
    }

    var hasEnabledData: Bool {
        !enabledSystemCategories.isEmpty || locationEnabled || photosEnabled || visitsEnabled
    }

    func isEnabled(_ category: SystemContextCategory) -> Bool {
        switch category {
        case .regional: regionalEnabled
        case .device: deviceEnabled
        case .network: networkEnabled
        }
    }

    func setEnabled(_ enabled: Bool, for category: SystemContextCategory) {
        switch category {
        case .regional: regionalEnabled = enabled
        case .device: deviceEnabled = enabled
        case .network: networkEnabled = enabled
        }
    }

    func scope(to counterpartyID: String?) {
        migrateLegacyValuesIfNeeded(to: counterpartyID)
        guard self.counterpartyID != counterpartyID else { return }

        self.counterpartyID = counterpartyID
        isLoadingScope = true
        defer { isLoadingScope = false }

        guard let counterpartyID else {
            regionalEnabled = false
            deviceEnabled = false
            networkEnabled = false
            locationEnabled = false
            backgroundLocationEnabled = false
            photosEnabled = false
            visitsEnabled = false
            visitEnrichmentEnabled = false
            return
        }

        regionalEnabled = storedValue(
            for: SystemContextCategory.regional.rawValue,
            counterpartyID: counterpartyID
        )
        deviceEnabled = storedValue(
            for: SystemContextCategory.device.rawValue,
            counterpartyID: counterpartyID
        )
        networkEnabled = storedValue(
            for: SystemContextCategory.network.rawValue,
            counterpartyID: counterpartyID
        )
        let storedLocationEnabled = storedValue(
            for: "location",
            counterpartyID: counterpartyID
        )
        let storedBackgroundLocationEnabled = storedValue(
            for: "background-location",
            counterpartyID: counterpartyID
        )
        let storedVisitsEnabled = storedValue(
            for: "visits",
            counterpartyID: counterpartyID
        )
        let storedVisitEnrichmentEnabled = storedValue(
            for: "visit-enrichment",
            counterpartyID: counterpartyID
        )
        locationEnabled = storedLocationEnabled
        backgroundLocationEnabled = storedLocationEnabled
            && storedBackgroundLocationEnabled
        // Visits are parented to location for the same reason background
        // updates are: a child left armed under a revoked parent resumes
        // silently when the parent is re-enabled.
        visitsEnabled = storedLocationEnabled && storedVisitsEnabled
        visitEnrichmentEnabled = visitsEnabled && storedVisitEnrichmentEnabled
        photosEnabled = storedValue(
            for: "photos",
            counterpartyID: counterpartyID
        )
        if !storedLocationEnabled, storedBackgroundLocationEnabled {
            defaults.set(
                false,
                forKey: Self.scopedKey(counterpartyID, "background-location")
            )
        }
        if !storedLocationEnabled, storedVisitsEnabled {
            defaults.set(false, forKey: Self.scopedKey(counterpartyID, "visits"))
        }
        if !visitsEnabled, storedVisitEnrichmentEnabled {
            defaults.set(false, forKey: Self.scopedKey(counterpartyID, "visit-enrichment"))
        }
    }

    func removeScope(for counterpartyID: String) {
        for suffix in Self.preferenceSuffixes {
            defaults.removeObject(forKey: Self.scopedKey(counterpartyID, suffix))
        }
        if self.counterpartyID == counterpartyID {
            scope(to: nil)
        }
    }

    private func persist(_ enabled: Bool, key: String) {
        guard !isLoadingScope, let counterpartyID else { return }
        defaults.set(enabled, forKey: Self.scopedKey(counterpartyID, key))
    }

    private func storedValue(for suffix: String, counterpartyID: String) -> Bool {
        defaults.bool(forKey: Self.scopedKey(counterpartyID, suffix))
    }

    private func migrateLegacyValuesIfNeeded(to counterpartyID: String?) {
        guard !defaults.bool(forKey: Self.migrationKey) else { return }

        for suffix in Self.preferenceSuffixes {
            let legacyKey = Self.legacyKey(suffix)
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            if let counterpartyID {
                defaults.set(
                    defaults.bool(forKey: legacyKey),
                    forKey: Self.scopedKey(counterpartyID, suffix)
                )
            }
            defaults.removeObject(forKey: legacyKey)
        }
        defaults.set(true, forKey: Self.migrationKey)
    }

    private nonisolated static let preferenceSuffixes = [
        SystemContextCategory.regional.rawValue,
        SystemContextCategory.device.rawValue,
        SystemContextCategory.network.rawValue,
        "location",
        "background-location",
        "photos",
        "visits",
        "visit-enrichment",
    ]

    private nonisolated static func legacyKey(_ suffix: String) -> String {
        legacyKeyPrefix + suffix
    }

    private nonisolated static func scopedKey(_ counterpartyID: String, _ suffix: String) -> String {
        scopedKeyPrefix + counterpartyID + "." + suffix
    }

}
