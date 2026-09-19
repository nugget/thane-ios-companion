import CoreLocation
import SwiftUI

struct SharingView: View {
    let profile: AgentProfile
    let counterparty: ThaneCounterparty

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                recipientCard
                systemContextCard
                locationCard
                photosCard
                disclosureCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sharing with \(counterparty.displayName)")
    }

    private var recipientCard: some View {
        AppCard(title: "Recipient") {
            if let evidence = profile.presentedIdentity {
                NavigationLink {
                    IdentityEvidenceView(profile: profile, evidence: evidence)
                } label: {
                    HStack(spacing: 12) {
                        ThaneIdentityMark(identityID: evidence.instance.id, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipientTitle(for: evidence))
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(profile.identityStatusLabel) · \(evidence.instance.shortFingerprint)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if !profile.identityContinuity.permitsPrivateDelivery {
                    Label(
                        profile.identityContinuity == .mismatch
                            ? "Sharing blocked by identity mismatch"
                            : "Sharing waits for an identity pin",
                        systemImage: profile.identityContinuity == .mismatch
                            ? "exclamationmark.shield.fill"
                            : "pin.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(profile.identityContinuity == .mismatch ? .red : .orange)
                }
            } else if let pin = profile.identityPinning.pin,
                      pin.identityID == counterparty.id {
                NavigationLink {
                    IdentityPinView(pin: pin)
                } label: {
                    HStack {
                        PinnedIdentitySummary(
                            pin: pin,
                            status: profile.identityStatusLabel
                        )
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the identity pinned on this iPhone")
                Text(pinnedRecipientDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(counterparty.displayName, systemImage: "lock.shield")
                    .font(.headline)
                Text("This sharing policy is unavailable until this counterparty is pinned on this iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemContextCard: some View {
        AppCard(title: "System Context") {
            ForEach(Array(SystemContextCategory.allCases.enumerated()), id: \.element.id) { index, category in
                if index > 0 { Divider() }
                Toggle(isOn: Binding(
                    get: { profile.sharingPreferences.isEnabled(category) },
                    set: { profile.setSystemCategory(category, enabled: $0) }
                )) {
                    PreferenceLabel(title: category.title, detail: category.detail)
                }
                .disabled(!canEditSharing)
            }
        }
    }

    private var locationCard: some View {
        AppCard(title: "Location") {
            Toggle(isOn: Binding(
                get: { profile.sharingPreferences.locationEnabled },
                set: { profile.setLocationSharing(enabled: $0) }
            )) {
                PreferenceLabel(
                    title: "Current Location",
                    detail: "Shares one Core Location fix per request, including accuracy and sensor provenance."
                )
            }
            .disabled(!canEditSharing)

            if profile.sharingPreferences.locationEnabled {
                Divider()

                Toggle(isOn: Binding(
                    get: { profile.sharingPreferences.backgroundLocationEnabled },
                    set: { profile.setBackgroundLocationSharing(enabled: $0) }
                )) {
                    PreferenceLabel(
                        title: "Background Location Updates",
                        detail: "Publishes the latest snapshot when iOS reports a significant location change. This is not continuous tracking."
                    )
                }
                .disabled(profile.locationService.authorizationStatus == .notDetermined)

                Divider()

                Toggle(isOn: Binding(
                    get: { profile.sharingPreferences.visitsEnabled },
                    set: { profile.setVisitSharing(enabled: $0) }
                )) {
                    PreferenceLabel(
                        title: "Visit History",
                        detail: "Shares places you stayed, with arrival and departure times and how long you were there, for up to the last 48 hours and 16 places. This is a record of where you spend time, not a single position, and Thane keeps what it receives. Separate from Background Location Updates and off until you turn it on."
                    )
                }
                .disabled(profile.locationService.authorizationStatus == .notDetermined)

                if PrivateCapabilities.appleMapsVisitEnrichmentAvailable,
                   profile.sharingPreferences.visitsEnabled {
                    Divider()
                    visitPlaceDetails
                }

                Divider()

                OperationalRow(
                    title: "Permission",
                    value: locationPermissionLabel,
                    systemImage: "location.circle",
                    color: locationPermissionColor
                )

                if profile.sharingPreferences.backgroundLocationEnabled {
                    OperationalRow(
                        title: "Monitor",
                        value: backgroundMonitorLabel,
                        systemImage: "wave.3.right.circle",
                        color: backgroundMonitorColor
                    )
                }

                if locationPermissionNeedsSettings || backgroundPermissionNeedsSettings {
                    Button("Open iOS Settings") {
                        profile.openIOSSettings()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var visitPlaceDetails: some View {
        Toggle(isOn: Binding(
            get: { profile.sharingPreferences.visitEnrichmentEnabled },
            set: { profile.setVisitEnrichment(enabled: $0) }
        )) {
            PreferenceLabel(
                title: "Visit Place Details",
                detail: "Sends recent and new visit coordinates to Apple Maps for street addresses and nearby businesses, then shares the results with \(counterparty.displayName), which keeps what it receives. Nearby businesses are possible matches; distances are straight-line estimates. Lookups are best effort and need no additional location permission. Available in development builds."
            )
        }
        .disabled(!canEditSharing)

        if profile.sharingPreferences.visitEnrichmentEnabled {
            if profile.visitEnrichment.isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking up visit places…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = profile.visitEnrichment.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let mapsURL = URL(string: "https://maps.apple.com") {
                Link("Place data from Apple Maps", destination: mapsURL)
                    .font(.caption)
            }
        }
    }

    private var photosCard: some View {
        AppCard(title: "Photos") {
            Toggle(isOn: Binding(
                get: { profile.sharingPreferences.photosEnabled },
                set: { enabled in
                    Task {
                        await profile.setPhotoSharing(enabled: enabled)
                    }
                }
            )) {
                PreferenceLabel(
                    title: "Recent Photo Metadata",
                    detail: "Shares metadata for up to 10 recent visible photos: dates, dimensions, favorite state, saved location, and selected camera, lens, and exposure fields. Photo pixels and hidden assets are never included."
                )
            }
            .disabled(!canEditSharing)

            if profile.photoService.authorizationStatus != .notDetermined {
                Divider()

                OperationalRow(
                    title: "Library Access",
                    value: photoPermissionLabel,
                    systemImage: "photo.on.rectangle.angled",
                    color: photoPermissionColor
                )

                if photoPermissionNeedsSettings {
                    Button("Open iOS Settings") {
                        profile.openIOSSettings()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            Label(
                "Embedded metadata is read only when the original is already on this iPhone. This source never downloads an iCloud original.",
                systemImage: "icloud.slash"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var disclosureCard: some View {
        AppCard {
            Label("Controlled on this iPhone", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Every source defaults off for \(counterparty.displayName). \(counterparty.displayName) cannot grant itself access or trigger an Apple permission prompt. Data shared with \(counterparty.displayName) is delivered only after current evidence matches this iPhone's identity pin, through the authenticated companion connection or an approved event-driven upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canEditSharing: Bool {
        profile.sharingPreferences.counterpartyID == counterparty.id
            && profile.identityPinning.pin?.identityID == counterparty.id
    }

    private var pinnedRecipientDetail: String {
        if profile.identityContinuity == .mismatch {
            return "The configured endpoint presents a different identity. Delivery remains blocked while this sharing policy stays attached to \(counterparty.displayName)."
        }
        return "Current evidence is unavailable. Live requests and observation uploads remain disabled until the endpoint presents identity evidence matching \(counterparty.displayName)."
    }

    private func recipientTitle(for evidence: ThaneIdentityEvidence) -> String {
        profile.identityContinuity.permitsPrivateDelivery
            ? "Shared with pinned \(evidence.instance.name)"
            : "Presented by \(evidence.instance.name)"
    }

    private var locationPermissionLabel: String {
        let authorization = profile.locationService.authorizationLabel
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        if let accuracy = profile.locationService.accuracyLabel {
            return "\(authorization) · \(accuracy.capitalized) accuracy"
        }
        return authorization
    }

    private var locationPermissionColor: Color {
        switch profile.locationService.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .green
        case .notDetermined: .orange
        case .denied, .restricted: .red
        @unknown default: .secondary
        }
    }

    private var locationPermissionNeedsSettings: Bool {
        switch profile.locationService.authorizationStatus {
        case .denied, .restricted: true
        default: false
        }
    }

    /// Either Always consumer stranded at When In Use needs the same route
    /// out. Keyed to background location alone, an operator who enabled only
    /// Visit History and declined the upgrade had no way back.
    private var backgroundPermissionNeedsSettings: Bool {
        (profile.sharingPreferences.backgroundLocationEnabled
            || profile.sharingPreferences.visitsEnabled)
            && profile.locationService.authorizationStatus != .authorizedAlways
            && profile.locationService.authorizationStatus != .notDetermined
    }

    private var backgroundMonitorLabel: String {
        if !profile.locationService.isSignificantLocationChangeMonitoringAvailable {
            return "Unavailable on this device"
        }
        return profile.locationService.isBackgroundMonitoringActive
            ? "Active"
            : "Waiting for Always permission"
    }

    private var backgroundMonitorColor: Color {
        if !profile.locationService.isSignificantLocationChangeMonitoringAvailable {
            return .red
        }
        return profile.locationService.isBackgroundMonitoringActive ? .green : .orange
    }

    private var photoPermissionLabel: String {
        switch profile.photoService.authorizationStatus {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .limited: "Selected Photos"
        case .full: "Full Library"
        }
    }

    private var photoPermissionColor: Color {
        switch profile.photoService.authorizationStatus {
        case .full: .green
        case .limited, .notDetermined: .orange
        case .denied, .restricted: .red
        }
    }

    private var photoPermissionNeedsSettings: Bool {
        switch profile.photoService.authorizationStatus {
        case .limited, .denied, .restricted: true
        case .notDetermined, .full: false
        }
    }
}

#if DEBUG
#Preview("Sharing") {
    let profile = PreviewFixtures.appState().activeProfile
    NavigationStack {
        SharingView(
            profile: profile,
            counterparty: PreviewFixtures.counterparty
        )
    }
}
#endif
