/// Private development features are unavailable in the distribution configuration.
nonisolated enum PrivateCapabilities {
    #if DEBUG
    static let appleMapsVisitEnrichmentAvailable = true
    static let visualContextAvailable = true
    #else
    static let appleMapsVisitEnrichmentAvailable = false
    static let visualContextAvailable = false
    #endif
}
