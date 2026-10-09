import Foundation

nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

@Observable
@MainActor
final class AppPreferences {
    private nonisolated static let appearanceKey = "app.appearance"
    private nonisolated static let visualContextKey = "app.visual-context-enabled"
    private let defaults: UserDefaults

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    var visualContextEnabled: Bool {
        didSet {
            defaults.set(visualContextEnabled, forKey: Self.visualContextKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        visualContextEnabled = PrivateCapabilities.visualContextAvailable
            && defaults.bool(forKey: Self.visualContextKey)
        appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:))
            ?? .automatic
    }
}
