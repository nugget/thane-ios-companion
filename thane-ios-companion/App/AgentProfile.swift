import CoreLocation
import Foundation
import SwiftUI
import UIKit

@Observable
@MainActor
final class AgentProfile: Identifiable {
    let id: String
    let connectionSettings: ConnectionSettings
    let sharingPreferences: SharingPreferences
    let connection: ServerConnection
    let platformRouter: PlatformServiceRouter
    let locationService: LocationService
    let visitWindow: VisitWindowStore
    let photoService: PhotoService
    let observationPublisher: ObservationPublisher
    let identityService: IdentityService
    let identityPinning: IdentityPinningService
    let conversationStore: ConversationStore
    let inboxStore: InboxStore

    @ObservationIgnored lazy var visitEnrichment = VisitEnrichmentCoordinator(
        store: visitWindow,
        currentScope: { [weak self] in self?.visitEnrichmentScope },
        prepareLookup: { [weak self] window in
            guard let self, self.visitEnrichmentScope != nil else { throw CancellationError() }
            try await self.observationPublisher.persistVisits(window)
        },
        publish: { [weak self] window in self?.publishVisits(window) }
    )

    var tokenInput: String = ""
    private(set) var configurationError: String?

    private let systemContextService: SystemContextService
    private let visitPlaceResolver: (any VisitPlaceResolving)?
    private var configuredVisitEnrichmentScope: String?
    private var identityRefreshDeadlineTask: Task<Void, Never>?

    /// Builds a profile whose every collaborator is wired to the same storage
    /// scope. Prefer this over the designated initializer: it is the only place
    /// that guarantees the profile ID, the preferences suite, and the durable
    /// storage locations agree.
    static func make(profileID: String, defaults: UserDefaults) -> AgentProfile {
        AgentProfile(
            connectionSettings: ConnectionSettings(profileID: profileID, defaults: defaults),
            sharingPreferences: SharingPreferences(defaults: defaults)
        )
    }

    init(
        connectionSettings: ConnectionSettings,
        sharingPreferences: SharingPreferences = SharingPreferences(),
        observationPublisher: ObservationPublisher? = nil,
        identityService: IdentityService = IdentityService(),
        identityPinning: IdentityPinningService? = nil,
        conversationStore: ConversationStore = ConversationStore(),
        inboxStore: InboxStore? = nil,
        photoLibrary: (any PhotoLibraryReading)? = nil,
        visitWindow: VisitWindowStore? = nil,
        locationManager: any LocationManaging = CLLocationManager(),
        visitPlaceResolver: (any VisitPlaceResolving)? = nil,
        locationAuthorizationSessionFactory: @escaping @MainActor () -> any LocationAuthorizationSession = {
            CLServiceSession(authorization: .always)
        }
    ) {
        let identityPinning = identityPinning ?? IdentityPinningService(
            connectionID: connectionSettings.connectionID
        )
        precondition(
            identityPinning.connectionID == connectionSettings.connectionID,
            "Identity storage must use the active connection profile scope."
        )
        // Sourced unconditionally from the settings object so no collaborator
        // can address a different SHA-256 storage directory than another.
        let profileID = connectionSettings.profileID
        let visitWindow = visitWindow ?? VisitWindowStore(profileID: profileID)
        let observationPublisher = observationPublisher ?? ObservationPublisher(
            outbox: ObservationOutbox(profileID: profileID),
            uploader: URLSessionObservationUploader(profileID: profileID)
        )
        self.visitWindow = visitWindow
        self.visitPlaceResolver = PrivateCapabilities.appleMapsVisitEnrichmentAvailable
            ? visitPlaceResolver ?? AppleVisitPlaceResolver() : nil
        self.id = profileID
        self.connectionSettings = connectionSettings
        self.sharingPreferences = sharingPreferences
        self.observationPublisher = observationPublisher
        self.identityService = identityService
        self.identityPinning = identityPinning
        self.conversationStore = conversationStore
        self.inboxStore = inboxStore ?? InboxStore(profileID: profileID)
        if let pinnedCounterpartyID = identityPinning.pin?.identityID {
            connectionSettings.bindPairwiseClientID(to: pinnedCounterpartyID)
        }
        sharingPreferences.scope(to: identityPinning.pin?.identityID)
        if !PrivateCapabilities.appleMapsVisitEnrichmentAvailable {
            sharingPreferences.visitEnrichmentEnabled = false
        }
        self.inboxStore.scope(to: identityPinning.pin?.identityID)

        let connection = ServerConnection()
        let router = PlatformServiceRouter()
        let systemService = SystemContextService(preferences: sharingPreferences)
        let locationService = LocationService(
            preferences: sharingPreferences, manager: locationManager,
            authorizationSessionFactory: locationAuthorizationSessionFactory
        )
        let photoService = PhotoService(
            preferences: sharingPreferences,
            library: photoLibrary ?? SystemPhotoLibraryReader(),
            identifierNamespace: { connectionSettings.pairwiseClientID }
        )

        self.connection = connection
        platformRouter = router
        systemContextService = systemService
        self.locationService = locationService
        self.photoService = photoService
        if locationService.authorizationStatus != .authorizedAlways {
            sharingPreferences.visitEnrichmentEnabled = false
        }
        observationPublisher.visitDisclosure = { [weak self] in
            guard let self,
                  self.sharingPreferences.locationEnabled,
                  self.sharingPreferences.visitsEnabled,
                  self.locationService.authorizationStatus == .authorizedAlways else { return .withdrawn }
            return PrivateCapabilities.appleMapsVisitEnrichmentAvailable && self.sharingPreferences.visitEnrichmentEnabled
                ? .enriched : .raw
        }

        locationService.onSignificantLocation = { [weak self, weak observationPublisher] snapshot in
            observationPublisher?.publishLocation(snapshot)
            self?.refreshIdentityOpportunistically()
        }
        locationService.onBackgroundLocationUnavailable = { [weak observationPublisher] in
            observationPublisher?.withdraw(.location)
        }
        locationService.onVisit = { [weak self] visit in
            guard let self else { return }
            do {
                publishVisits(try visitWindow.record(visit))
                resumeVisitEnrichment()
            } catch {
                configurationError = "The visit history could not be saved on this iPhone. Place details will wait."
                // Raw capture can still reach the durable outbox while local
                // history storage recovers. Enrichment requires both writes.
                publishVisits(visitWindow.window())
            }
            refreshIdentityOpportunistically()
        }
        locationService.onVisitMonitoringUnavailable = { [weak self, weak observationPublisher] in
            self?.invalidateVisitEnrichment()
            self?.sharingPreferences.visitEnrichmentEnabled = false
            observationPublisher?.reconcileVisitDisclosure()
            self?.visitWindow.discardAll()
            observationPublisher?.withdraw(.visits)
        }
        systemService.setChangeHandler { [weak self] in
            self?.publishSystemContextIfEnabled()
        }

        router.register(
            capability: "ios.system-context",
            handler: SystemContextPlatformHandler(service: systemService)
        )
        router.register(
            capability: "ios.location",
            handler: LocationPlatformHandler(service: locationService)
        )
        router.register(
            capability: "ios.photos",
            handler: PhotoPlatformHandler(service: photoService)
        )
        router.register(
            capability: "ios.visits",
            handler: VisitsPlatformHandler(
                store: visitWindow,
                preferences: sharingPreferences
            )
        )
        connection.registeredCapabilities = router.capabilities
        connection.onPlatformRequest = { [weak router] request in
            guard let router else {
                return PlatformResponse(
                    id: request.id,
                    type: "result",
                    success: false,
                    result: nil,
                    error: WSError(code: "unavailable", message: "Platform router unavailable")
                )
            }
            return await router.handle(request: request)
        }
        connection.onConnected = { [weak observationPublisher] in
            // Observation authentication resolves this client ID through the
            // durable inventory written by a successful realtime handshake.
            observationPublisher?.flush()
        }
        connection.onAuthenticationFailure = { [weak self] in
            self?.connectionSettings.isEnabled = false
            self?.suspendObservationDelivery()
        }
        connection.onReconnectValidationRequested = { [weak self] in
            self?.refreshIdentityBeforeReconnect()
        }
        identityService.onEvidenceUpdated = { [weak self] evidence in
            // Persist before reconciling: a later launch with no scene reads
            // this snapshot to decide whether it may deliver at all.
            // Bound to the endpoint it came from: the connection ID that
            // scopes its Keychain account survives a URL edit, so the address
            // has to travel with the snapshot.
            if let source = self?.identityService.sourceURL {
                self?.identityPinning.storeEvidence(evidence, from: source)
            }
            self?.scheduleIdentityRefreshDeadline(for: evidence)
            self?.reconcileIdentityBoundary()
        }
        identityService.onRefreshFailed = { [weak self] in
            self?.cancelIdentityRefreshDeadline()
            self?.reconcileIdentityBoundary()
        }

        do {
            tokenInput = try connectionSettings.storedToken() ?? ""
            if !tokenInput.isEmpty {
                // Re-saving migrates tokens created by older builds to the
                // after-first-unlock accessibility required for a location wake.
                try connectionSettings.saveToken(tokenInput)
            }
        } catch {
            configurationError = error.localizedDescription
        }
        configureObservationPublisher()
        // Authorization reconciliation can emit withdrawals even when the
        // previous observation was already acknowledged. Bind its recipient first.
        locationService.restoreBackgroundMonitoringIfAuthorized()
        if !sharingPreferences.visitEnrichmentEnabled {
            removeVisitPlaceContext()
        }
        resumeVisitEnrichment()
    }

    var statusTitle: String {
        if connection.state == .disconnected {
            if identityService.isRefreshing { return "Checking Identity" }
            switch identityContinuity {
            case .presented: return "Awaiting Pin"
            case .mismatch: return "Identity Mismatch"
            case .stale: return "Identity Evidence Stale"
            case .unavailable where connectionSettings.isEnabled: return "Identity Unavailable"
            default: break
            }
        }
        return switch connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting · \(attempt)"
        }
    }

    var statusSymbol: String {
        if connection.state == .disconnected {
            if identityService.isRefreshing { return "person.badge.shield.checkmark" }
            switch identityContinuity {
            case .presented: return "pin.circle"
            case .mismatch: return "exclamationmark.shield.fill"
            case .stale: return "clock.badge.exclamationmark"
            case .unavailable where connectionSettings.isEnabled: return "questionmark.diamond"
            default: break
            }
        }
        return switch connection.state {
        case .connected: "checkmark.circle.fill"
        case .connecting, .authenticating, .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .disconnected: "circle.dashed"
        }
    }

    var hasActiveConnection: Bool {
        connection.state != .disconnected
    }

    var displayedError: String? {
        configurationError ?? identityPinning.lastError ?? connection.lastError
    }

    var hasConnectionCredentials: Bool {
        connectionSettings.serverURL != nil
            && !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasConnectionConfiguration: Bool {
        identityPinning.pin != nil
            || !connectionSettings.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var counterparty: ThaneCounterparty? {
        if let pin = identityPinning.pin {
            return ThaneCounterparty(
                pin: pin,
                presentedEvidence: presentedIdentity
            )
        }
        if let evidence = presentedIdentity {
            return ThaneCounterparty(evidence: evidence)
        }
        return nil
    }

    var presentedIdentity: ThaneIdentityEvidence? {
        identityService.evidence(for: connectionSettings.serverURL)
    }

    var identityContinuity: IdentityContinuityState {
        IdentityContinuityState.evaluate(
            pin: identityPinning.pin,
            evidence: presentedIdentity
        )
    }

    var identityStatusLabel: String {
        switch identityContinuity {
        case .notPinned: "Not pinned"
        case .presented: "Presented · review before pinning"
        case .matching: "Pinned and matching"
        case .stale: "Pinned match · evidence is stale"
        case .unavailable: "Pinned · current evidence unavailable"
        case .mismatch: "Identity mismatch · delivery blocked"
        }
    }

    var hasVerifiedReportedCoreChecks: Bool {
        guard let evidence = presentedIdentity else { return false }
        return evidence.core.verification.admission.isVerified
            && evidence.core.verification.head.isVerified
    }

    func activate() {
        locationService.restoreBackgroundMonitoringIfAuthorized()
        resumeVisitEnrichment()
        photoService.refreshAuthorizationStatus()
        // A foreground transition must revalidate the current endpoint and
        // token before either transport can release private data.
        suspendPrivateDelivery()
        publishSystemContextIfEnabled()
        guard connectionSettings.isEnabled else { return }
        refreshIdentityForConfiguredConnection()
    }

    func enterBackground() {
        invalidateVisitEnrichment()
        cancelIdentityRefreshDeadline()
        connection.disconnect()
    }

    func connectUsingCurrentValues() {
        configurationError = nil
        cancelIdentityRefreshDeadline()
        guard let url = connectionSettings.serverURL else {
            configurationError = "Enter an HTTPS agent server URL. HTTP is accepted only for loopback development."
            return
        }

        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            configurationError = "Enter an agent API token."
            return
        }

        do {
            try connectionSettings.saveToken(token)
        } catch {
            configurationError = error.localizedDescription
            return
        }

        connectionSettings.isEnabled = true
        suspendPrivateDelivery()
        refreshIdentityEvidence(from: url, token: token)
    }

    func disconnect() {
        cancelIdentityRefreshDeadline()
        connectionSettings.isEnabled = false
        suspendPrivateDelivery()
    }

    func refreshIdentity() {
        configurationError = nil
        cancelIdentityRefreshDeadline()
        guard let url = connectionSettings.serverURL else {
            configurationError = "Enter a valid agent server URL before refreshing identity evidence."
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            configurationError = "Enter an agent API token before refreshing identity evidence."
            return
        }
        suspendPrivateDelivery()
        refreshIdentityEvidence(from: url, token: token)
    }

    func pinPresentedIdentity() {
        configurationError = nil
        guard let evidence = presentedIdentity else {
            configurationError = "Refresh identity evidence before pinning this agent."
            return
        }
        pin(evidence)
    }

    func pin(_ evidence: ThaneIdentityEvidence) {
        configurationError = nil
        do {
            try identityPinning.pin(evidence)
            connectionSettings.bindPairwiseClientID(to: evidence.instance.id)
        } catch {
            configurationError = error.localizedDescription
            return
        }
        applySharingScope(evidence.instance.id)
        inboxStore.scope(to: evidence.instance.id)
        reconcileIdentityBoundary()
    }

    func forgetThane() async {
        invalidateVisitEnrichment()
        configurationError = nil
        cancelIdentityRefreshDeadline()
        connectionSettings.isEnabled = false
        connection.disconnect()
        // The window is keyed by profile, and the profile ID survives removal —
        // so without this a replacement agent bound to the same profile would
        // inherit the removed agent's visit history the moment Visit History
        // was switched on.
        visitWindow.discardAll()
        do {
            try await observationPublisher.discardAllPending()
            try identityPinning.forget()
            applySharingScope(nil)
            inboxStore.scope(to: nil)
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func removeConnection() async {
        invalidateVisitEnrichment()
        configurationError = nil
        cancelIdentityRefreshDeadline()
        connectionSettings.isEnabled = false
        connection.disconnect()
        let counterpartyID = identityPinning.pin?.identityID
            ?? connectionSettings.pairwiseCounterpartyID

        do {
            try connectionSettings.deleteToken()
            tokenInput = ""
            visitWindow.discardAll()
            try identityPinning.forget()
            try await observationPublisher.discardAllPending()
            try inboxStore.discardAllProfileData()
            if let counterpartyID {
                sharingPreferences.removeScope(for: counterpartyID)
            }
            applySharingScope(nil)
            connectionSettings.removeConfiguration()
            suspendObservationDelivery()
            connection.clearRetainedDiagnostics()
            try identityPinning.changeScope(to: connectionSettings.connectionID)
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func forgetToken() {
        configurationError = nil
        do {
            try connectionSettings.deleteToken()
        } catch {
            configurationError = error.localizedDescription
            return
        }

        tokenInput = ""
        disconnect()
    }

    func setSystemCategory(_ category: SystemContextCategory, enabled: Bool) {
        guard sharingPreferences.counterpartyID == identityPinning.pin?.identityID,
              sharingPreferences.counterpartyID != nil else {
            configurationError = "Pin this agent before changing what is shared with it."
            return
        }
        sharingPreferences.setEnabled(enabled, for: category)
        if category == .network {
            systemContextService.setNetworkObservationEnabled(enabled)
        } else if category == .device {
            systemContextService.setDeviceObservationEnabled(enabled)
        }
        publishSystemContextIfEnabled(withdrawIfDisabled: true)
    }

    func setLocationSharing(enabled: Bool) {
        guard sharingPreferences.counterpartyID == identityPinning.pin?.identityID,
              sharingPreferences.counterpartyID != nil else {
            configurationError = "Pin this agent before changing what is shared with it."
            return
        }
        if !enabled { invalidateVisitEnrichment() }
        if !enabled, sharingPreferences.backgroundLocationEnabled {
            locationService.setBackgroundMonitoringEnabled(false)
            observationPublisher.withdraw(.location)
        }
        sharingPreferences.locationEnabled = enabled
        observationPublisher.reconcileVisitDisclosure()
        if enabled {
            locationService.requestWhenInUseAuthorizationIfNeeded()
        } else {
            locationService.cancelPendingRequestAfterConsentRevocation()
        }
    }

    func setBackgroundLocationSharing(enabled: Bool) {
        guard sharingPreferences.counterpartyID == identityPinning.pin?.identityID,
              sharingPreferences.counterpartyID != nil else {
            configurationError = "Pin this agent before changing what is shared with it."
            return
        }
        locationService.setBackgroundMonitoringEnabled(enabled)
        if !enabled {
            observationPublisher.withdraw(.location)
        }
    }

    func setVisitSharing(enabled: Bool) {
        guard sharingPreferences.counterpartyID == identityPinning.pin?.identityID,
              sharingPreferences.counterpartyID != nil else {
            configurationError = "Pin this agent before changing what is shared with it."
            return
        }
        if !enabled { invalidateVisitEnrichment() }
        locationService.setVisitMonitoringEnabled(enabled)
        observationPublisher.reconcileVisitDisclosure()
        if !enabled {
            // Erase the on-device window as well as withdrawing, so nothing
            // remains here to republish if it is switched back on.
            visitWindow.discardAll()
            observationPublisher.withdraw(.visits)
        }
    }

    func setVisitEnrichment(enabled: Bool) {
        guard let scope = sharingPreferences.counterpartyID,
              scope == identityPinning.pin?.identityID else {
            configurationError = "Pin this agent before changing what is shared with it."
            return
        }
        configurationError = nil
        invalidateVisitEnrichment()
        sharingPreferences.visitEnrichmentEnabled = enabled
            && PrivateCapabilities.appleMapsVisitEnrichmentAvailable
            && locationService.authorizationStatus == .authorizedAlways
        observationPublisher.reconcileVisitDisclosure()
        if sharingPreferences.visitEnrichmentEnabled {
            resumeVisitEnrichment()
        } else {
            removeVisitPlaceContext()
            if enabled, locationService.authorizationStatus != .authorizedAlways {
                configurationError = "Enable Visit History with Always location permission before turning on place details."
            }
        }
    }

    private var visitEnrichmentScope: String? {
        guard PrivateCapabilities.appleMapsVisitEnrichmentAvailable,
              sharingPreferences.visitEnrichmentEnabled,
              sharingPreferences.locationEnabled, sharingPreferences.visitsEnabled,
              locationService.authorizationStatus == .authorizedAlways,
              identityContinuity != .mismatch,
              let scope = sharingPreferences.counterpartyID,
              scope == identityPinning.pin?.identityID else { return nil }
        return scope
    }

    private func resumeVisitEnrichment() {
        guard let scope = visitEnrichmentScope, let visitPlaceResolver else {
            invalidateVisitEnrichment()
            return
        }
        if configuredVisitEnrichmentScope == scope {
            visitEnrichment.resume()
        } else {
            configuredVisitEnrichmentScope = scope
            visitEnrichment.configure(scope: scope, resolver: visitPlaceResolver)
        }
    }

    private func invalidateVisitEnrichment() {
        configuredVisitEnrichmentScope = nil
        visitEnrichment.invalidate()
    }

    private func removeVisitPlaceContext() {
        do {
            publishVisits(try visitWindow.removePlaceContext())
        } catch {
            // Reads and publications also strip context, even if disk cleanup fails.
            configurationError = "Saved place details could not be removed. Place detail sharing is off."
            publishVisits(visitWindow.window().withoutPlaceContext())
        }
    }

    private func publishVisits(_ window: VisitWindowSnapshot) {
        guard sharingPreferences.locationEnabled, sharingPreferences.visitsEnabled,
              locationService.authorizationStatus == .authorizedAlways else { return }
        let includePlaceContext = PrivateCapabilities.appleMapsVisitEnrichmentAvailable
            && sharingPreferences.visitEnrichmentEnabled
        observationPublisher.publishVisits(includePlaceContext ? window : window.withoutPlaceContext())
    }

    func setPhotoSharing(enabled: Bool) async {
        configurationError = nil
        guard let counterpartyID = sharingPreferences.counterpartyID,
              counterpartyID == identityPinning.pin?.identityID else {
            configurationError = "Pin this agent before changing what is shared with it."
            return
        }
        guard enabled else {
            sharingPreferences.photosEnabled = false
            photoService.cancelPendingRequestAfterConsentRevocation()
            return
        }

        let authorization = await photoService.requestAuthorizationFromOperatorAction()
        guard sharingPreferences.counterpartyID == counterpartyID,
              identityPinning.pin?.identityID == counterpartyID else {
            return
        }
        if authorization.permitsRead {
            sharingPreferences.photosEnabled = true
        } else {
            sharingPreferences.photosEnabled = false
            configurationError = switch authorization {
            case .notDetermined:
                "Photos permission was not selected."
            case .denied:
                "Photos permission is denied. It can be changed in iOS Settings."
            case .restricted:
                "Photos access is restricted on this device."
            case .limited, .full:
                nil
            }
        }
    }

    func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func configureObservationPublisher() {
        guard identityPinning.pin != nil else {
            observationPublisher.configure(
                baseURL: nil,
                token: nil,
                clientID: "",
                deliveryScope: nil,
                authorizationExpiresAt: nil
            )
            return
        }
        guard connectionSettings.isEnabled else {
            observationPublisher.configure(
                baseURL: nil,
                token: nil,
                clientID: "",
                deliveryScope: observationDeliveryScope,
                authorizationExpiresAt: nil
            )
            return
        }

        // Live evidence, verified this session. Unchanged: the fifteen-minute
        // window still governs a foreground app that can refresh at will.
        if identityContinuity.permitsPrivateDelivery, let evidence = presentedIdentity {
            observationPublisher.configure(
                baseURL: connectionSettings.serverURL,
                token: tokenInput,
                clientID: connectionSettings.pairwiseClientID,
                deliveryScope: observationDeliveryScope,
                authorizationExpiresAt: evidence.observedAt.addingTimeInterval(
                    IdentityContinuityState.maximumEvidenceAge
                )
            )
            return
        }

        // No live evidence. A process launched by Core Location has no scene
        // and cannot fetch any, so refusing here is what made a wake record
        // and never send. The stored snapshot still has to match the pin —
        // continuity is intact and this phone cannot be pointed at a
        // different Thane — only recency is relaxed, to the ceiling.
        if let restored = identityPinning.restoredEvidence(for: connectionSettings.serverURL) {
            observationPublisher.configure(
                baseURL: connectionSettings.serverURL,
                token: tokenInput,
                clientID: connectionSettings.pairwiseClientID,
                deliveryScope: observationDeliveryScope,
                // From verifiedAt, stamped by this device, not from the
                // server-supplied observedAt.
                authorizationExpiresAt: restored.verifiedAt.addingTimeInterval(
                    IdentityContinuityState.maximumStoredEvidenceAge
                )
            )
            return
        }

        observationPublisher.configure(
            baseURL: nil,
            token: nil,
            clientID: "",
            deliveryScope: observationDeliveryScope,
            authorizationExpiresAt: nil
        )
    }

    /// Tries to freshen identity evidence from a background wake.
    ///
    /// Deliberately not `refreshIdentityForConfiguredConnection`, which
    /// suspends delivery *before* fetching: on a wake with no route — which
    /// is exactly when a wake is likely to fire — that would tear down the
    /// destination this snapshot just authorised. On success the live path
    /// takes over and the window narrows back to fifteen minutes; on failure
    /// the stored snapshot continues to authorise delivery.
    private func refreshIdentityOpportunistically() {
        guard connectionSettings.isEnabled,
              identityContinuity.permitsPrivateDelivery == false,
              let url = connectionSettings.serverURL else { return }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        identityService.refresh(from: url, token: token)
    }

    private func applySharingScope(_ counterpartyID: String?) {
        invalidateVisitEnrichment()
        // The window was gathered for the previous counterparty. Scoped by
        // profile rather than by counterparty, it would otherwise carry across
        // the boundary the rest of this method exists to enforce.
        visitWindow.discardAll()
        locationService.suspendForCounterpartyChange()
        photoService.suspendForCounterpartyChange()
        sharingPreferences.scope(to: counterpartyID)
        if !PrivateCapabilities.appleMapsVisitEnrichmentAvailable {
            sharingPreferences.visitEnrichmentEnabled = false
        }
        observationPublisher.reconcileVisitDisclosure()
        systemContextService.setNetworkObservationEnabled(sharingPreferences.networkEnabled)
        systemContextService.setDeviceObservationEnabled(sharingPreferences.deviceEnabled)
        locationService.restoreBackgroundMonitoringIfAuthorized()
        resumeVisitEnrichment()
    }

    private func refreshIdentityForConfiguredConnection() {
        guard let url = connectionSettings.serverURL else { return }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        suspendPrivateDelivery()
        refreshIdentityEvidence(from: url, token: token)
    }

    private func reconcileIdentityBoundary() {
        resumeVisitEnrichment()
        guard connectionSettings.isEnabled else {
            configureObservationPublisher()
            return
        }
        guard identityContinuity.permitsPrivateDelivery,
              let url = connectionSettings.serverURL else {
            connection.disconnect()
            if identityContinuity == .mismatch {
                // A different identity is presenting itself. The stored
                // snapshot still matches the pin, so falling back to it here
                // would paper over exactly the thing worth refusing.
                suspendObservationDelivery()
                let name = identityPinning.pin?.nameAtPinning ?? "the pinned agent"
                configurationError = "The presented identity does not match \(name)'s pin on this iPhone. Private delivery is blocked."
                return
            }
            // No live evidence (a fetch that failed, or a launch with no
            // scene) or evidence merely gone stale. Re-derive the
            // destination rather than clearing it: configureObservationPublisher
            // falls back to the stored snapshot, which is what a background
            // wake depends on and what an opportunistic refresh must not be
            // able to destroy by failing.
            configureObservationPublisher()
            if identityContinuity == .stale {
                configurationError = "Identity evidence is more than 15 minutes old. Refresh it before private delivery resumes."
            }
            return
        }
        configurationError = nil
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        establishMatchedConnection(url: url, token: token)
    }

    private func establishMatchedConnection(url: URL, token: String) {
        configureObservationPublisher()
        publishSystemContextIfEnabled()
        observationPublisher.flush()
        switch connection.state {
        case .reconnecting:
            connection.resumeConnectionAfterIdentityValidation()
        case .disconnected:
            connection.connect(
                url: url,
                token: token,
                clientID: connectionSettings.pairwiseClientID,
                clientName: "Thane for iOS"
            )
        case .connecting, .authenticating, .connected:
            break
        }
    }

    private func suspendPrivateDelivery() {
        suspendObservationDelivery()
        connection.disconnect()
    }

    private func suspendObservationDelivery() {
        observationPublisher.configure(
            baseURL: nil,
            token: nil,
            clientID: "",
            deliveryScope: observationDeliveryScope,
            authorizationExpiresAt: nil
        )
    }

    private func refreshIdentityBeforeReconnect() {
        guard connectionSettings.isEnabled,
              let url = connectionSettings.serverURL else {
            suspendPrivateDelivery()
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            suspendPrivateDelivery()
            return
        }

        cancelIdentityRefreshDeadline()
        suspendObservationDelivery()
        refreshIdentityEvidence(from: url, token: token)
    }

    private func refreshIdentityEvidence(from url: URL, token: String) {
        connection.prepareForIdentityRefresh(from: url)
        identityService.refresh(from: url, token: token)
    }

    private func scheduleIdentityRefreshDeadline(for evidence: ThaneIdentityEvidence) {
        cancelIdentityRefreshDeadline()
        guard connectionSettings.isEnabled else { return }
        let delay = evidence.observedAt
            .addingTimeInterval(IdentityContinuityState.maximumEvidenceAge)
            .timeIntervalSinceNow
        guard delay > 0 else { return }

        identityRefreshDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.connectionSettings.isEnabled,
                  self.presentedIdentity == evidence else {
                return
            }
            self.refreshIdentityForConfiguredConnection()
        }
    }

    private func cancelIdentityRefreshDeadline() {
        identityRefreshDeadlineTask?.cancel()
        identityRefreshDeadlineTask = nil
    }

    private var observationDeliveryScope: ObservationDeliveryScope? {
        identityPinning.pin.map {
            ObservationDeliveryScope(
                connectionID: connectionSettings.connectionID,
                identityID: $0.identityID
            )
        }
    }

    private func publishSystemContextIfEnabled(withdrawIfDisabled: Bool = false) {
        do {
            observationPublisher.publishSystemContext(try systemContextService.snapshot())
        } catch SystemContextServiceError.noCategoriesEnabled {
            if withdrawIfDisabled {
                observationPublisher.withdraw(.systemContext)
            }
        } catch {
            configurationError = error.localizedDescription
        }
    }
}
