import PhotosUI
import SwiftUI

struct VisualContextView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = VisualContextService()
    @State private var selection: PhotosPickerItem?
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionGeneration = UUID()
    @State private var isLoadingSelection = false
    @State private var selectionError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable Image Analysis", isOn: Binding(
                    get: { appState.appPreferences.visualContextEnabled },
                    set: { enabled in
                        appState.appPreferences.visualContextEnabled = enabled
                        reset()
                        service.setEnabled(enabled)
                    }
                ))
            } footer: {
                Text("Analyze only an image you choose, using Apple's on-device model. The companion holds the image and its interpretation only in memory. Leaving this screen cancels analysis and clears the preview. Nothing is sent to an agent. This choice is separate from Recent Photo Metadata sharing.")
            }

            if appState.appPreferences.visualContextEnabled {
                Section {
                    Label(service.availability.message, systemImage: service.availability.isAvailable
                        ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(service.availability.isAvailable ? .secondary : .primary)

                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Choose and Analyze Image", systemImage: "photo.badge.magnifyingglass")
                    }
                    .disabled(!service.availability.isAvailable || isBusy || scenePhase != .active)

                    if isBusy {
                        HStack {
                            ProgressView()
                            Text(isLoadingSelection ? "Opening selected image…" : "Analyzing on this iPhone…")
                        }
                        Button("Cancel", role: .cancel) { reset() }
                    }

                    if let error = selectionError ?? service.lastError?.errorDescription {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("The Photos picker may download the image you select from iCloud. Analysis begins only after selection. Choose a still image under 20 MB; its size is reduced for analysis.")
                }
            }

            if let result = service.result {
                Section {
                    Text(result.summary)
                        .textSelection(.enabled)
                    if !result.visibleText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Visible text").font(.caption).foregroundStyle(.secondary)
                            Text(result.visibleText.joined(separator: "\n"))
                                .textSelection(.enabled)
                        }
                    }
                    if !result.uncertainties.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uncertainty").font(.caption).foregroundStyle(.secondary)
                            Text(result.uncertainties.joined(separator: "\n"))
                        }
                    }
                    Text(result.processedAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear Result", role: .destructive) { reset() }
                } header: {
                    Text("Image Context")
                } footer: {
                    Text("AI interpretation can be wrong. Check descriptions and transcribed text against the original image before using them.")
                }
            }
        }
        .navigationTitle("Image Context Preview")
        .onAppear {
            service.setEnabled(appState.appPreferences.visualContextEnabled)
        }
        .onChange(of: selection) { _, selected in
            load(selected)
        }
        .onChange(of: appState.appPreferences.visualContextEnabled) { _, enabled in
            reset()
            service.setEnabled(enabled)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reset() }
        }
        .onDisappear { reset() }
    }

    private var isBusy: Bool { isLoadingSelection || service.isAnalyzing }

    private func load(_ selected: PhotosPickerItem?) {
        cancelWork()
        service.clear()
        selectionError = nil
        guard let selected,
              scenePhase == .active,
              appState.appPreferences.visualContextEnabled,
              service.availability.isAvailable else { return }

        let generation = selectionGeneration
        isLoadingSelection = true
        selectionTask = Task { @MainActor in
            do {
                guard let image = try await selected.loadTransferable(type: VisualContextImageSelection.self) else {
                    throw VisualContextSelectionError.unreadable
                }
                try Task.checkCancellation()
                guard generation == selectionGeneration,
                      scenePhase == .active,
                      appState.appPreferences.visualContextEnabled else { return }
                isLoadingSelection = false
                await service.analyze(data: image.data)
            } catch is CancellationError {
                // Revocation or navigation intentionally ends this selection.
            } catch {
                guard generation == selectionGeneration else { return }
                selectionError = (error as? VisualContextSelectionError)?.errorDescription
                    ?? "This image could not be opened. Choose another image."
            }
            guard generation == selectionGeneration else { return }
            isLoadingSelection = false
            selectionTask = nil
        }
    }

    private func cancelWork() {
        selectionGeneration = UUID()
        selectionTask?.cancel()
        selectionTask = nil
        isLoadingSelection = false
        service.cancel()
    }

    private func reset() {
        cancelWork()
        service.clear()
        selection = nil
        selectionError = nil
    }
}
