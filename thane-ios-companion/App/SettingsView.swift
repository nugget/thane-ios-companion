import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Companion App") {
                NavigationLink {
                    AppSettingsView()
                } label: {
                    LabeledContent {
                        Text(appState.appPreferences.appearance.title)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("App Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }

            Section {
                if appState.configuredProfiles.isEmpty {
                    NavigationLink {
                        AgentSettingsView(profile: appState.activeProfile)
                    } label: {
                        Label("Add Agent", systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    ForEach(appState.configuredProfiles) { profile in
                        NavigationLink {
                            AgentSettingsView(profile: profile)
                        } label: {
                            ConnectionRow(profile: profile)
                        }
                    }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Each agent owns its identity, sharing policy, and connection settings. Adding or removing a connection stays within that agent's settings.")
            }

            if PrivateCapabilities.visualContextAvailable {
                Section {
                    NavigationLink {
                        VisualContextView()
                    } label: {
                        Label("Image Context Preview", systemImage: "photo.badge.magnifyingglass")
                    }
                } header: {
                    Text("On This iPhone")
                } footer: {
                    Text("Try an on-device interpretation of an image you choose. Available in development builds.")
                }
            }

            Section("About") {
                LabeledContent("App version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): build
        case (nil, nil): "Unknown"
        }
    }
}

private struct AppSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { appState.appPreferences.appearance },
                    set: { appState.appPreferences.appearance = $0 }
                )) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Automatic follows this iPhone's current Light or Dark appearance.")
            }
        }
        .navigationTitle("App Settings")
    }
}

private extension AppAppearance {
    var systemImage: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

private struct ConnectionRow: View {
    let profile: AgentProfile

    var body: some View {
        HStack(spacing: 12) {
            if let counterparty = profile.counterparty {
                ThaneIdentityMark(identityID: counterparty.id, size: 44)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.counterparty?.displayName ?? connectionHost)
                    .font(.headline)
                Text(profile.counterparty == nil ? "Identity not pinned" : profile.identityStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if profile.counterparty != nil {
                    Text(connectionHost)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var connectionHost: String {
        profile.connectionSettings.serverURL?.host()
            ?? profile.connectionSettings.urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Unconfigured Agent"
    }
}

private struct ConnectionStatusSection: View {
    let statusTitle: String
    let statusSymbol: String
    let statusColor: Color
    let account: String?
    let serverVersion: String?
    let serverStartedAt: Date?
    let protocolVersion: String?

    var body: some View {
        Section("Connection Status") {
            HStack(alignment: .firstTextBaseline) {
                Text("Status")
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                    Text(statusTitle)
                }
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(statusColor)
            }
            .accessibilityElement(children: .combine)

            if let account {
                LabeledContent("Account", value: account)
            }
            if let serverVersion {
                LabeledContent("Server version", value: serverVersion)
            }
            if let serverStartedAt {
                LabeledContent("Uptime") {
                    Text(serverStartedAt, style: .timer)
                        .monospacedDigit()
                }
            }
            if let protocolVersion {
                LabeledContent("Protocol version", value: protocolVersion)
            }
        }
    }
}

private struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: AgentProfile
    @State private var urlString = ""
    @State private var token = ""
    @State private var hasLoadedValues = false
    @State private var showingForgetTokenConfirmation = false
    @State private var showingForgetThaneConfirmation = false
    @State private var showingRemovalConfirmation = false

    var body: some View {
        Form {
            if let counterparty = profile.counterparty {
                Section("Agent") {
                    HStack(spacing: 12) {
                        ThaneIdentityMark(identityID: counterparty.id, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(counterparty.displayName)
                                .font(.headline)
                            Text(counterparty.shortFingerprint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(profile.identityStatusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Information & Access") {
                    NavigationLink {
                        identityDetail(for: counterparty)
                    } label: {
                        LabeledContent {
                            Text(profile.identityStatusLabel)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Identity & Trust", systemImage: "person.badge.shield.checkmark")
                        }
                    }

                    NavigationLink {
                        SharingView(profile: profile, counterparty: counterparty)
                    } label: {
                        LabeledContent {
                            Text(sharingSummary(for: counterparty))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Shared Information", systemImage: "hand.raised.fill")
                        }
                    }
                }
            }

            ConnectionStatusSection(
                statusTitle: profile.statusTitle,
                statusSymbol: profile.statusSymbol,
                statusColor: statusColor,
                account: profile.connection.account,
                serverVersion: profile.connection.serverVersion,
                serverStartedAt: profile.connection.serverStartedAt,
                protocolVersion: profile.connection.protocolVersion
            )

            Section("Configuration") {
                TextField("https://thane.example.com", text: $urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .disabled(profile.hasActiveConnection)

                SecureField("API token", text: $token)
                    .textContentType(.password)
                    .disabled(profile.hasActiveConnection)

                if profile.hasActiveConnection {
                    Text("Disconnect before editing connection credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Pairwise Client ID") {
                    Text(profile.connectionSettings.pairwiseClientID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Connection Privacy")
            } footer: {
                Text("This random identifier is stable for reconnecting to this counterparty and is never reused for another agent connection.")
            }

            if let error = profile.displayedError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if profile.hasActiveConnection {
                    Button("Disconnect", role: .destructive) {
                        profile.disconnect()
                    }
                } else {
                    Button(profile.identityPinning.pin == nil ? "Check Identity" : "Connect") {
                        applyDraftAndConnect()
                    }
                    .disabled(!draftHasCredentials)
                }

                Button("Forget API Token", role: .destructive) {
                    showingForgetTokenConfirmation = true
                }
                .disabled(profile.tokenInput.isEmpty)

                if profile.identityPinning.pin != nil || profile.identityPinning.lastError != nil {
                    Button("Forget Identity Pin", role: .destructive) {
                        showingForgetThaneConfirmation = true
                    }
                }
            } footer: {
                Text("The API token and identity pin are stored in this iPhone's protected Keychain. Private delivery starts only after current evidence matches the pin.")
            }

            if profile.hasConnectionConfiguration {
                Section {
                    Button("Remove Connection", role: .destructive) {
                        showingRemovalConfirmation = true
                    }
                } footer: {
                    Text("Removal also deletes this counterparty's sharing choices and queued observations from this iPhone.")
                }
            }
        }
        .navigationTitle(profile.counterparty == nil ? "Add Agent" : "Agent Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadValuesIfNeeded)
        .onChange(of: profile.connectionSettings.urlString) { _, newValue in
            urlString = newValue
        }
        .onChange(of: profile.tokenInput) { _, newValue in
            token = newValue
        }
        .confirmationDialog(
            "Forget this API token?",
            isPresented: $showingForgetTokenConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget API Token", role: .destructive) {
                profile.forgetToken()
                token = ""
            }
        } message: {
            Text("The app will disconnect and remove the credential from Keychain. This counterparty's sharing choices are unchanged.")
        }
        .confirmationDialog(
            "Forget this identity pin?",
            isPresented: $showingForgetThaneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Identity Pin", role: .destructive) {
                Task { await profile.forgetThane() }
            }
        } message: {
            Text("The app will disconnect, remove the identity pin, and discard queued observations. Connection credentials and this counterparty's saved sharing choices are unchanged.")
        }
        .confirmationDialog(
            "Remove this agent connection?",
            isPresented: $showingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Connection", role: .destructive) {
                Task {
                    await profile.removeConnection()
                    if !profile.hasConnectionConfiguration {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("The API token, identity pin, sharing choices, and queued observations for this agent will be removed from this iPhone.")
        }
    }

    private var statusColor: Color {
        switch profile.connection.state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .disconnected: .secondary
        }
    }

    private var draftHasCredentials: Bool {
        ServerAddress.parse(urlString) != nil
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadValuesIfNeeded() {
        guard !hasLoadedValues else { return }
        urlString = profile.connectionSettings.urlString
        token = profile.tokenInput
        hasLoadedValues = true
    }

    private func applyDraftAndConnect() {
        profile.connectionSettings.urlString = urlString
        profile.tokenInput = token
        profile.connectUsingCurrentValues()
    }

    @ViewBuilder
    private func identityDetail(for counterparty: ThaneCounterparty) -> some View {
        if let evidence = profile.presentedIdentity {
            IdentityEvidenceView(profile: profile, evidence: evidence)
        } else if let pin = profile.identityPinning.pin,
                  pin.identityID == counterparty.id {
            IdentityPinView(pin: pin)
        } else {
            ContentUnavailableView(
                "Identity Unavailable",
                systemImage: "person.badge.shield.checkmark",
                description: Text("No current or pinned identity evidence is available for this agent.")
            )
            .navigationTitle("Identity")
        }
    }

    private func sharingSummary(for counterparty: ThaneCounterparty) -> String {
        guard profile.sharingPreferences.counterpartyID == counterparty.id else {
            return "Unavailable"
        }
        let systemCount = profile.sharingPreferences.enabledSystemCategories.count
        let count = systemCount + (profile.sharingPreferences.locationEnabled ? 1 : 0)
        return count == 0 ? "Nothing enabled" : "\(count) source\(count == 1 ? "" : "s") enabled"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .environment(PreviewFixtures.appState())
}

#Preview("App Settings") {
    NavigationStack {
        AppSettingsView()
    }
    .environment(PreviewFixtures.appState())
}

#Preview("Agent Settings") {
    let profile = PreviewFixtures.appState().activeProfile
    NavigationStack {
        AgentSettingsView(profile: profile)
    }
}

#Preview("Connected Status") {
    Form {
        ConnectionStatusSection(
            statusTitle: "Connected",
            statusSymbol: "checkmark.circle.fill",
            statusColor: .green,
            account: "mcphone",
            serverVersion: "v0.10.3-330-g56f345f8",
            serverStartedAt: Date().addingTimeInterval(-7_423),
            protocolVersion: "0.1.0"
        )
    }
}
#endif
