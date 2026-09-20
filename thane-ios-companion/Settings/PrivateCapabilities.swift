/// Private development features are unavailable in the distribution configuration.
nonisolated enum PrivateCapabilities {
    #if DEBUG
    static let appleMapsVisitEnrichmentAvailable = true
    #else
    static let appleMapsVisitEnrichmentAvailable = false
    #endif
}
