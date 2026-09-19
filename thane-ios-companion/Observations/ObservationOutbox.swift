import CryptoKit
import Foundation

nonisolated enum ObservationOutboxError: LocalizedError, Sendable {
    case unavailable(String)
    case identityRequired
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "Observation queue unavailable: \(message)"
        case .identityRequired:
            "Observation queue requires a connection and pinned Thane identity."
        case .identityMismatch:
            "Observation queue belongs to a different connection or Thane identity."
        }
    }
}

private nonisolated struct ObservationOutboxEnvelope: Codable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let connectionID: String
    let identityID: String
    let events: [ObservationEvent]

    init(scope: ObservationDeliveryScope, events: [ObservationEvent]) {
        schemaVersion = Self.currentSchemaVersion
        connectionID = scope.connectionID
        identityID = scope.identityID
        self.events = events
    }

    var scope: ObservationDeliveryScope {
        ObservationDeliveryScope(connectionID: connectionID, identityID: identityID)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case connectionID = "connection_id"
        case identityID = "identity_id"
        case events
    }
}

private nonisolated struct LegacyObservationOutboxEnvelope: Codable {
    let schemaVersion: Int
    let identityID: String
    let events: [ObservationEvent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case identityID = "identity_id"
        case events
    }
}

actor ObservationOutbox {
    private let fileURL: URL
    private let storageURLResolved: Bool
    private var scope: ObservationDeliveryScope?
    private var eventsByKind: [ObservationKind: ObservationEvent] = [:]
    private var initializationError: ObservationOutboxError?
    private var legacyIdentityID: String?
    private var legacyEventCount = 0

    init(
        fileURL: URL? = nil,
        profileID: String? = nil,
        storageDirectoryURL: URL? = nil
    ) {
        var resolvedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thane-observations-unavailable.json")
        var loadedScope: ObservationDeliveryScope?
        var loadedEvents: [ObservationKind: ObservationEvent] = [:]
        var loadError: ObservationOutboxError?
        var loadedLegacyIdentityID: String?
        var loadedLegacyEventCount = 0
        var didResolveStorageURL = false
        do {
            if let fileURL {
                resolvedURL = fileURL
            } else if let profileID, !profileID.isEmpty {
                let storageDirectoryURL = try storageDirectoryURL
                    ?? Self.defaultStorageDirectoryURL()
                resolvedURL = Self.profileFileURL(
                    profileID: profileID,
                    storageDirectoryURL: storageDirectoryURL
                )
                try Self.migrateLegacyOutboxIfNeeded(
                    storageDirectoryURL: storageDirectoryURL,
                    destinationURL: resolvedURL
                )
            } else {
                throw ObservationOutboxError.unavailable(
                    "A stable profile ID is required for persisted queue storage."
                )
            }
            didResolveStorageURL = true
            if FileManager.default.fileExists(atPath: resolvedURL.path) {
                let data = try Data(contentsOf: resolvedURL)
                let events: [ObservationEvent]
                if let envelope = try? ObservationCoding.decoder().decode(
                    ObservationOutboxEnvelope.self,
                    from: data
                ), envelope.schemaVersion == ObservationOutboxEnvelope.currentSchemaVersion,
                   !envelope.connectionID.isEmpty,
                   !envelope.identityID.isEmpty {
                    loadedScope = envelope.scope
                    events = envelope.events
                } else if let legacyEnvelope = try? ObservationCoding.decoder().decode(
                    LegacyObservationOutboxEnvelope.self,
                    from: data
                ), legacyEnvelope.schemaVersion == 1,
                   !legacyEnvelope.identityID.isEmpty {
                    loadedLegacyIdentityID = legacyEnvelope.identityID
                    events = legacyEnvelope.events
                } else if let legacyEvents = try? ObservationCoding.decoder().decode(
                    [ObservationEvent].self,
                    from: data
                ) {
                    // Version 1 of the app stored a bare event array without a
                    // recipient. Those events cannot safely be assigned to a
                    // newly pinned identity, so remember only the discard count.
                    loadedLegacyEventCount = legacyEvents.count
                    events = []
                } else {
                    throw ObservationOutboxError.unavailable(
                        "The saved queue is unreadable or uses an unsupported storage schema."
                    )
                }
                for event in events {
                    guard let existing = loadedEvents[event.kind] else {
                        loadedEvents[event.kind] = event
                        continue
                    }
                    if Self.shouldReplace(existing, with: event) {
                        loadedEvents[event.kind] = event
                    }
                }
            }
        } catch let error as ObservationOutboxError {
            loadError = error
        } catch {
            loadError = .unavailable(error.localizedDescription)
        }
        self.fileURL = resolvedURL
        storageURLResolved = didResolveStorageURL
        scope = loadedScope
        eventsByKind = loadedEvents
        initializationError = loadError
        legacyIdentityID = loadedLegacyIdentityID
        legacyEventCount = loadedLegacyEventCount
    }

    @discardableResult
    func bind(to scope: ObservationDeliveryScope) throws -> Int {
        try Task.checkCancellation()
        try ensureAvailable()
        guard !scope.connectionID.isEmpty, !scope.identityID.isEmpty else {
            throw ObservationOutboxError.identityRequired
        }
        if let existingScope = self.scope {
            guard existingScope == scope else {
                throw ObservationOutboxError.identityMismatch
            }
            return 0
        }
        if let legacyIdentityID,
           legacyIdentityID != scope.identityID {
            throw ObservationOutboxError.identityMismatch
        }

        let discardedCount = legacyEventCount
        let previousScope = self.scope
        let previousLegacyIdentityID = legacyIdentityID
        self.scope = scope
        self.legacyIdentityID = nil
        legacyEventCount = 0
        do {
            try persist()
        } catch {
            self.scope = previousScope
            legacyIdentityID = previousLegacyIdentityID
            legacyEventCount = discardedCount
            throw error
        }
        return discardedCount
    }

    func enqueue(_ event: ObservationEvent, for scope: ObservationDeliveryScope) throws {
        try Task.checkCancellation()
        try bind(to: scope)
        try Task.checkCancellation()
        let previous = eventsByKind[event.kind]
        if let previous, !Self.shouldReplace(previous, with: event) {
            return
        }
        eventsByKind[event.kind] = event
        do {
            try persist()
        } catch {
            eventsByKind[event.kind] = previous
            throw error
        }
    }

    func pending(for scope: ObservationDeliveryScope) throws -> [ObservationEvent] {
        try ensureAvailable()
        try requireScope(scope)
        return eventsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// A privacy repair must not overwrite a newer observation queued while
    /// the caller was awaiting this actor.
    func replacePending(
        _ event: ObservationEvent, replacing eventID: UUID, for scope: ObservationDeliveryScope
    ) throws -> Bool {
        try Task.checkCancellation()
        try ensureAvailable()
        try requireScope(scope)
        guard eventsByKind[event.kind]?.eventID == eventID else { return false }
        try enqueue(event, for: scope)
        return eventsByKind[event.kind]?.eventID == event.eventID
    }

    func removeSent(_ eventIDs: Set<UUID>, for scope: ObservationDeliveryScope) throws {
        try Task.checkCancellation()
        try ensureAvailable()
        try requireScope(scope)
        let previous = eventsByKind
        eventsByKind = eventsByKind.filter { !eventIDs.contains($0.value.eventID) }
        do {
            try persist()
        } catch {
            eventsByKind = previous
            throw error
        }
    }

    func discardAll(for scope: ObservationDeliveryScope) throws {
        try ensureAvailable()
        if let existingScope = self.scope,
           existingScope != scope {
            throw ObservationOutboxError.identityMismatch
        }
        if let legacyIdentityID,
           legacyIdentityID != scope.identityID {
            throw ObservationOutboxError.identityMismatch
        }

        try discardAll()
    }

    func discardAll() throws {
        let previousScope = scope
        let previousEvents = eventsByKind
        let previousLegacyIdentityID = legacyIdentityID
        let previousLegacyEventCount = legacyEventCount
        scope = nil
        eventsByKind = [:]
        legacyIdentityID = nil
        legacyEventCount = 0
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            if storageURLResolved {
                initializationError = nil
            }
        } catch {
            scope = previousScope
            eventsByKind = previousEvents
            legacyIdentityID = previousLegacyIdentityID
            legacyEventCount = previousLegacyEventCount
            throw error
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let scope else { throw ObservationOutboxError.identityRequired }
        let envelope = ObservationOutboxEnvelope(
            scope: scope,
            events: eventsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
        let data = try ObservationCoding.encoder().encode(envelope)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func ensureAvailable() throws {
        if let initializationError {
            throw initializationError
        }
    }

    private func requireScope(_ scope: ObservationDeliveryScope) throws {
        guard let existingScope = self.scope else {
            throw ObservationOutboxError.identityRequired
        }
        guard existingScope == scope else {
            throw ObservationOutboxError.identityMismatch
        }
    }

    private nonisolated static func shouldReplace(
        _ existing: ObservationEvent,
        with candidate: ObservationEvent
    ) -> Bool {
        guard candidate.eventID != existing.eventID else { return false }
        if candidate.observedAt != existing.observedAt {
            return candidate.observedAt > existing.observedAt
        }
        if candidate.status != existing.status {
            return candidate.status == .withdrawn
        }
        return candidate.eventID.uuidString > existing.eventID.uuidString
    }

    nonisolated static func profileFileURL(
        profileID: String,
        storageDirectoryURL: URL
    ) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return storageDirectoryURL
            .appendingPathComponent("observation-outboxes", isDirectory: true)
            .appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private nonisolated static func defaultStorageDirectoryURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("info.nugget.thane-ios-companion", isDirectory: true)
    }

    private nonisolated static func migrateLegacyOutboxIfNeeded(
        storageDirectoryURL: URL,
        destinationURL: URL
    ) throws {
        let legacyURL = storageDirectoryURL
            .appendingPathComponent("observation-outbox.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: legacyURL, to: destinationURL)
    }
}
