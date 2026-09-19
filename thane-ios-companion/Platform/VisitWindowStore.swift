import CryptoKit
import Foundation

/// Holds the recent-visit window on disk so it survives the relaunches this
/// feature depends on.
///
/// It has to persist. Core Location relaunches the app to deliver a visit, and
/// the outbox keeps exactly one event per kind — so an in-memory window would
/// reset on every launch and each publish would replace the server's row with a
/// single entry, destroying the history it is supposed to carry.
///
/// Scoped by profile and file-protected the way the outbox is: two agents must
/// not share a window, and a window must be readable during the after-first-
/// unlock period a background wake actually runs in.
@MainActor
final class VisitWindowStore {
    private let fileURL: URL
    private var visits: [VisitSnapshot] = []
    /// The anchor of the newest visit the cap discarded.
    ///
    /// A bare in-memory flag was wrong twice over: it reset on relaunch, so a
    /// reloaded window under-reported, and it never expired, so once set every
    /// future window claimed truncation long after the dropped visit had aged
    /// out. Storing the anchor makes the answer both durable and cutoff-aware.
    private var lastDroppedAnchor: Date?

    init(profileID: String, storageDirectoryURL: URL? = nil) {
        let directory = (try? storageDirectoryURL ?? Self.defaultStorageDirectoryURL())
            ?? FileManager.default.temporaryDirectory
        fileURL = Self.profileFileURL(profileID: profileID, storageDirectoryURL: directory)
        restore()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        restore()
    }

    private func restore() {
        guard let stored = try? load() else { return }
        // Older windows keyed stays by coordinates as well as arrival, so a
        // refined departure could leave both versions on disk.
        for visit in stored.visits {
            if let key = visit.stayKey,
               let index = visits.firstIndex(where: { $0.stayKey == key }) {
                visits[index] = replacing(visits[index], with: visit)
            } else {
                visits.append(visit)
            }
        }
        lastDroppedAnchor = stored.lastDroppedAnchor
    }

    /// Records a visit and returns the window to publish.
    ///
    /// Visits are keyed by their arrival so the settled callback replaces the
    /// ongoing one for the same stay rather than appearing twice — Core
    /// Location delivers both.
    @discardableResult
    func record(_ visit: VisitSnapshot, now: Date = Date()) -> VisitWindowSnapshot {
        var recorded = visit
        // Replace only when both sides name the same stay. Matching on a nil
        // arrival would fold every missed-arrival visit into one, discarding
        // unrelated places that happen to share a coordinate.
        if let key = visit.stayKey {
            if let existing = visits.first(where: { $0.stayKey == key }) {
                recorded = replacing(existing, with: visit)
            }
            visits.removeAll { $0.stayKey == key }
        }
        visits.append(recorded)
        prune(now: now)
        try? persist()
        return window(now: now)
    }

    private func replacing(_ existing: VisitSnapshot, with incoming: VisitSnapshot) -> VisitSnapshot {
        if existing.state == .settled, incoming.state == .ongoing { return existing }
        var replacement = incoming
        replacement.visitID = existing.visitID
        replacement.placeContext = existing.hasSameLookupLocation(as: incoming)
            ? existing.placeContext ?? incoming.placeContext
            : nil
        return replacement
    }

    func visit(id: UUID, now: Date = Date()) -> VisitSnapshot? {
        window(now: now).visits.first { $0.visitID == id }
    }

    /// Apply an asynchronous result to the current entry, never the snapshot
    /// that started the lookup: a departure may have arrived in the meantime.
    @discardableResult
    func applyPlaceContext(
        _ context: VisitPlaceContext, to id: UUID,
        expectedVisit: VisitSnapshot? = nil, now: Date = Date()
    ) throws -> VisitWindowSnapshot? {
        guard let current = visit(id: id, now: now),
              expectedVisit.map({ current.hasSameLookupLocation(as: $0) }) ?? true,
              let index = visits.firstIndex(where: { $0.visitID == id }) else {
            return nil
        }
        let previous = visits[index].placeContext
        visits[index].placeContext = context
        do {
            try persist()
        } catch {
            visits[index].placeContext = previous
            throw error
        }
        return window(now: now)
    }

    /// Revoking enrichment preserves the original visits. Keep memory clear
    /// even if persistence fails so the caller can prevent further exposure.
    @discardableResult
    func removePlaceContext(now: Date = Date()) throws -> VisitWindowSnapshot {
        for index in visits.indices {
            visits[index].placeContext = nil
        }
        try persist()
        return window(now: now)
    }

    /// The window as of `now`, with the age cutoff applied on read.
    ///
    /// Pruning on write alone was not enough: between callbacks nothing runs,
    /// and a file loaded at launch is arbitrarily old, so a 48-hour window
    /// could return week-old entries and still advertise 48 hours.
    func window(now: Date = Date()) -> VisitWindowSnapshot {
        let cutoff = now.addingTimeInterval(-VisitWindowSnapshot.windowHours * 3600)
        let fresh = visits.filter { $0.anchorDate >= cutoff }
        let ordered = fresh.sorted { $0.anchorDate > $1.anchorDate }
        let kept = Array(ordered.prefix(VisitWindowSnapshot.maxEntries))
        return VisitWindowSnapshot(
            capturedAt: ObservationCoding.dateString(from: now),
            windowHours: VisitWindowSnapshot.windowHours,
            maxEntries: VisitWindowSnapshot.maxEntries,
            returnedCount: kept.count,
            // True only when something was dropped that would still belong to
            // this window. Deriving it from the already-capped store made it
            // permanently false; an unexpiring flag made it permanently true.
            truncated: (lastDroppedAnchor.map { $0 >= cutoff } ?? false)
                || ordered.count > kept.count,
            visits: kept
        )
    }

    var isEmpty: Bool { visits.isEmpty }

    /// Erases the window. Called wherever the operator withdraws visits, so
    /// turning the category off leaves nothing on the device to republish.
    /// Erases the window, and reports whether the on-disk copy is really gone.
    ///
    /// Swallowing the failure emptied memory while leaving the file, so the
    /// next launch reloaded a history the operator had withdrawn. When removal
    /// fails, an empty window is written over it so a stale file cannot be
    /// mistaken for valid history, and the caller is told.
    @discardableResult
    func discardAll() -> Bool {
        visits = []
        lastDroppedAnchor = nil
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return true
        } catch {
            try? persist()
            return false
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-VisitWindowSnapshot.windowHours * 3600)
        visits.removeAll { $0.anchorDate < cutoff }
        if visits.count > VisitWindowSnapshot.maxEntries {
            // Record what was lost before it becomes unobservable. Capping
            // here is what makes `ordered.count > kept.count` false at read.
            let ordered = visits.sorted { $0.anchorDate > $1.anchorDate }
            if let newestDropped = ordered.dropFirst(VisitWindowSnapshot.maxEntries).first {
                lastDroppedAnchor = max(lastDroppedAnchor ?? .distantPast, newestDropped.anchorDate)
            }
            visits = Array(ordered.prefix(VisitWindowSnapshot.maxEntries))
        }
    }

    private struct StoredWindow: Codable {
        var visits: [VisitSnapshot]
        var lastDroppedAnchor: Date?

        enum CodingKeys: String, CodingKey {
            case visits
            case lastDroppedAnchor = "last_dropped_anchor"
        }
    }

    private func load() throws -> StoredWindow {
        let data = try Data(contentsOf: fileURL)
        return try ObservationCoding.decoder().decode(StoredWindow.self, from: data)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try ObservationCoding.encoder().encode(
            StoredWindow(visits: visits, lastDroppedAnchor: lastDroppedAnchor)
        )
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    nonisolated static func profileFileURL(
        profileID: String,
        storageDirectoryURL: URL
    ) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return storageDirectoryURL
            .appendingPathComponent("visit-windows", isDirectory: true)
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
}

/// The agent-facing read of the recent-visit window.
///
/// Answers from the on-device window rather than from Core Location: visits
/// arrive on the system's schedule, so there is nothing to "request" the way a
/// location fix can be requested. This reports what has already been observed.
@MainActor
struct VisitsPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["get_recent_visits"]
    let toolDefinitions = [
        PlatformToolDefinition.make(
            name: "ios_recent_visits",
            description: "Recent places the operator lingered, with arrival and departure times, from the active iOS companion. Covers at most the last 48 hours and 16 visits. Requires Visit History and iOS Always location permission. Ongoing visits have no departure and partial dwell; unobserved arrivals are unknown. Optional place_context contains separately enabled address lookups and nearby business candidates, never proof of a business visit. Candidate distance_meters is straight-line surface distance from the reported coordinate, not walking or driving distance. Preserve provider, timestamps, search radius, partial/truncated status, and location accuracy when interpreting results.",
            method: "get_recent_visits",
            tags: ["ios", "location", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {}
            }
            """
        ),
    ]

    private let store: VisitWindowStore
    private let preferences: SharingPreferences

    init(store: VisitWindowStore, preferences: SharingPreferences) {
        self.store = store
        self.preferences = preferences
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard method == "get_recent_visits" else {
            throw VisitsHandlerError.unsupportedMethod(method)
        }
        // Re-checked at answer time, not assumed from whatever armed
        // monitoring: the operator may have revoked since.
        guard preferences.locationEnabled, preferences.visitsEnabled else {
            throw VisitsHandlerError.sharingDisabled
        }
        let window = store.window()
        let includePlaceContext = PrivateCapabilities.appleMapsVisitEnrichmentAvailable
            && preferences.visitEnrichmentEnabled
        return try AnyCodable.fromEncodable(includePlaceContext ? window : window.withoutPlaceContext())
    }
}

nonisolated enum VisitsHandlerError: PlatformServiceError {
    case sharingDisabled
    case unsupportedMethod(String)

    var code: String {
        switch self {
        case .sharingDisabled: "visit_sharing_disabled"
        case .unsupportedMethod: "unknown_method"
        }
    }

    var errorDescription: String? {
        switch self {
        case .sharingDisabled:
            "Visit History is turned off for this agent in the iOS companion."
        case .unsupportedMethod(let method):
            "The visits capability does not support \(method)."
        }
    }
}
