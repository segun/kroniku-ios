import Foundation
import CryptoKit
import SwiftData

extension Notification.Name {
    static let memoryRepositoryChanged = Notification.Name("memoryRepositoryChanged")
}

enum MemoryRepositoryError: LocalizedError, Equatable {
    case emptyContactMoment
    case invalidInteraction

    var errorDescription: String? {
        switch self {
        case .emptyContactMoment:
            return "Add a note or person before saving this moment."
        case .invalidInteraction:
            return "Select a valid interaction type."
        }
    }
}

/// A small repository wrapper around a SwiftData ModelContext.
protocol MemoryRepositoryProtocol {
    func fetchAll() -> [MemoryEvent]
    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String, contextEnrichment: ContextEnrichment?, photoAttachments: [PhotoAttachment], resolvedContactIdentifier: String?, extractionReview: Tier2ExtractionReview?, bluetoothContext: BluetoothContextKind?, confidenceScore: Double?, linkedEventIDs: [UUID], contactNames: [String], resolvedContactIdentifiers: [String], endedAt: Date?, includeHealthData: Bool) throws
    @discardableResult
    func addDerivedEvent(source: String, title: String, detail: String?, occurredAt: Date, endedAt: Date?, motion: MotionState?, place: VisitSnapshot?, confidenceScore: Double?) throws -> MemoryEvent
    func reconcileDerivedEvents(_ drafts: [DerivedEventDraft], in interval: DateInterval) throws
    func syncCalendarEvents(_ imported: [TimelineCalendarImportEvent], for day: Date, attendeeLocationSharingEnabled: Bool) throws
    func applyRetentionPolicy(for consent: Tier1ConsentState) throws
    func delete(event: MemoryEvent) throws
    func update(event: MemoryEvent) throws
    func linkEvent(_ eventID: UUID, to linkedEventIDs: [UUID]) throws
    func fetchUnsyncedEvents() -> [MemoryEvent]
    func markSynced(eventId: String, version: Int, syncedAt: Date) throws
    func applyConflict(eventId: String, serverVersion: Int, strategy: String) throws
    func mergePulledEvents(_ events: [PullEventResponse]) throws
    func makePushRequest(for event: MemoryEvent) -> PushEventRequest
}

final class SwiftDataMemoryRepository: MemoryRepositoryProtocol {
    private let modelContext: ModelContext
    private let fetchDescriptor: FetchDescriptor<MemoryEvent>

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.fetchDescriptor = FetchDescriptor<MemoryEvent>(
            sortBy: [SortDescriptor(\MemoryEvent.occurredAt, order: .reverse)]
        )
    }

    func fetchAll() -> [MemoryEvent] {
        do {
            return try modelContext.fetch(fetchDescriptor).filter { !$0.isDeleted }
        } catch {
            print("Repository fetch failed: \(error)")
            return []
        }
    }

    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String = "typed", contextEnrichment: ContextEnrichment? = nil, photoAttachments: [PhotoAttachment] = [], resolvedContactIdentifier: String? = nil, extractionReview: Tier2ExtractionReview? = nil, bluetoothContext: BluetoothContextKind? = nil, confidenceScore: Double? = nil, linkedEventIDs: [UUID] = [], contactNames: [String] = [], resolvedContactIdentifiers: [String] = [], endedAt: Date? = nil, includeHealthData: Bool = false) throws {
        let trimmedPersonName = personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactNames = contactNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        guard !(trimmedNote.isEmpty && (trimmedPersonName?.isEmpty ?? true) && trimmedContactNames.isEmpty) else {
            throw MemoryRepositoryError.emptyContactMoment
        }

        guard let interaction = Interaction(rawValue: interactionType) else {
            throw MemoryRepositoryError.invalidInteraction
        }

        let cm = ContactMoment(
            personName: trimmedPersonName?.isEmpty == true ? nil : trimmedPersonName,
            interactionType: interaction.rawValue,
            occurredAt: occurredAt,
            endedAt: endedAt,
            note: trimmedNote,
            captureMethod: captureMethod,
            resolvedContactIdentifier: resolvedContactIdentifier,
            contactNames: trimmedContactNames,
            resolvedContactIdentifiers: resolvedContactIdentifiers
        )

        var metadata: [ContextCard.MetadataEntry] = [
            .init(key: "interactionType", value: interaction.rawValue),
            .init(key: "captureMethod", value: captureMethod)
        ]
        if let bluetoothContext {
            metadata.append(.init(key: "bluetoothContext", value: bluetoothContext.rawValue))
        }
        if !trimmedContactNames.isEmpty {
            metadata.append(.init(key: "contacts", value: trimmedContactNames.joined(separator: ",")))
        }
        if let endedAt {
            metadata.append(.init(key: "endedAt", value: ISO8601DateFormatter().string(from: endedAt)))
        }
        metadata.append(.init(key: "includeHealthData", value: String(includeHealthData)))

        let contextCard = ContextCard(
            source: "contactMoment",
            category: "moment",
            summary: trimmedNote,
            metadata: metadata
        )
        // searchText mirrors what should be full-text searchable on the backend (note is already the title).
        let searchText = ([interaction.title] + trimmedContactNames).joined(separator: " ")
        let me = MemoryEvent(
            occurredAt: occurredAt,
            source: "contactMoment",
            title: cm.note,
            detail: trimmedContactNames.isEmpty ? cm.personName : trimmedContactNames.joined(separator: ", "),
            context: searchText,
            contextCard: contextCard,
            symbolName: interaction.symbol,
            colorName: "indigo",
            extractionReview: extractionReview,
            photoAttachments: photoAttachments
        )

        me.linkedEventIDs = linkedEventIDs
        me.confidenceScore = confidenceScore
        me.includeHealthData = includeHealthData

        apply(enrichment: contextEnrichment, to: me)

        cm.memoryEvent = me
        me.contactMoment = cm

        modelContext.insert(cm)
        modelContext.insert(me)

        try modelContext.save()

        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    /// Creates a system-derived memory event (e.g. an inferred trip or workout) with no ContactMoment backing it.
    @discardableResult
    func addDerivedEvent(source: String, title: String, detail: String?, occurredAt: Date, endedAt: Date?, motion: MotionState?, place: VisitSnapshot?, confidenceScore: Double?) throws -> MemoryEvent {
        var metadata: [ContextCard.MetadataEntry] = []
        if let motion {
            metadata.append(.init(key: "motion", value: motion.rawValue))
        }
        if let endedAt {
            metadata.append(.init(key: "endedAt", value: ISO8601DateFormatter().string(from: endedAt)))
        }

        let event = MemoryEvent(
            occurredAt: occurredAt,
            source: source,
            title: title,
            detail: detail,
            context: title,
            contextCard: ContextCard(source: source, category: "derived", summary: detail ?? title, metadata: metadata),
            symbolName: Self.symbolName(source: source, title: title, motion: motion),
            colorName: Self.colorName(source: source, title: title),
            confidenceScore: confidenceScore,
            derivedEndedAt: endedAt
        )

        if let place {
            event.place = Place(name: place.name, latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        }

        modelContext.insert(event)
        try modelContext.save()

        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
        return event
    }

    private static func symbolName(source: String, title: String, motion: MotionState?) -> String {
        switch source {
        case "workout": return "figure.run"
        case "geofence": return "mappin.circle"
        case "sleep": return title == "Woke up" ? "sun.max.fill" : "moon.stars.fill"
        default: return motion == .walking ? "figure.walk" : "car.fill"
        }
    }

    private static func colorName(source: String, title: String) -> String {
        switch source {
        case "workout": return "green"
        case "geofence": return "indigo"
        case "sleep": return title == "Woke up" ? "orange" : "indigo"
        default: return "teal"
        }
    }

    func reconcileDerivedEvents(_ drafts: [DerivedEventDraft], in interval: DateInterval) throws {
        var existing = fetchStoredEvents().filter { event in
            guard !event.isDeleted, event.source == "trip" || event.source == "workout",
                  let start = event.occurredAt else { return false }
            let end = event.derivedEndedAt ?? start
            return start < interval.end && end > interval.start
        }
        var changed = false

        for draft in drafts.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            let bestIndex = existing.indices
                .filter { existing[$0].source == draft.source && existing[$0].title == draft.title }
                .max { lhs, rhs in
                    overlapScore(existing[lhs], draft) < overlapScore(existing[rhs], draft)
                }

            if let bestIndex, overlapScore(existing[bestIndex], draft) >= 0.5 {
                let event = existing.remove(at: bestIndex)
                changed = apply(draft, to: event) || changed
            } else {
                let prior = bestIndex.map { existing[$0] }
                insertDerivedEvent(draft, preserving: prior)
                changed = true
            }
        }

        for event in existing {
            event.isDeleted = true
            event.updatedAt = Date()
            event.backendVersion = max(1, event.backendVersion + 1)
            event.syncedToBackendAt = nil
            changed = true
        }

        guard changed else { return }
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    private func overlapScore(_ event: MemoryEvent, _ draft: DerivedEventDraft) -> Double {
        guard let start = event.occurredAt, let end = event.derivedEndedAt, end > start else { return 0 }
        let overlap = max(0, min(end, draft.endedAt).timeIntervalSince(max(start, draft.occurredAt)))
        return overlap / max(end.timeIntervalSince(start), draft.endedAt.timeIntervalSince(draft.occurredAt))
    }

    private func apply(_ draft: DerivedEventDraft, to event: MemoryEvent) -> Bool {
        let oldMotion = event.contextCard?.metadata.first(where: { $0.key == "motion" })?.value
        let newMotion = draft.motion?.rawValue
        let oldBluetooth = event.contextCard?.metadata.first(where: { $0.key == "bluetoothContext" })?.value
        let newBluetooth = draft.bluetoothContext?.rawValue
        let oldMedia = event.contextCard?.metadata.first(where: { $0.key == "mediaNowPlaying" })?.value
        let newMedia = draft.mediaNowPlaying?.displayText
        let placeChanged = event.place?.name != draft.place?.name ||
            event.place?.latitude != draft.place?.coordinate.latitude ||
            event.place?.longitude != draft.place?.coordinate.longitude
        let changed = event.occurredAt != draft.occurredAt || event.derivedEndedAt != draft.endedAt ||
            event.detail != draft.detail || oldMotion != newMotion || oldBluetooth != newBluetooth || placeChanged ||
            event.confidenceScore != draft.confidenceScore || event.distanceMeters != draft.distanceMeters || oldMedia != newMedia
        guard changed else { return false }

        event.occurredAt = draft.occurredAt
        event.derivedEndedAt = draft.endedAt
        event.detail = draft.detail
        event.context = draft.title
        let userMetadata = event.contextCard?.metadata.filter { $0.key == "userNote" || $0.key == "contacts" } ?? []
        let healthSummary = event.healthSummary
        event.contextCard = derivedContextCard(for: draft, preserving: userMetadata)
        event.healthSummary = healthSummary
        event.includeHealthData = draft.source == "workout" || draft.source == "sleep"
        event.distanceMeters = draft.distanceMeters
        event.workoutRoute = draft.route
        event.symbolName = derivedSymbol(for: draft)
        event.colorName = draft.source == "workout" ? "green" : "teal"
        event.confidenceScore = draft.confidenceScore
        event.place = draft.place.map { Place(name: $0.name, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        event.updatedAt = Date()
        event.backendVersion = max(1, event.backendVersion + 1)
        event.syncedToBackendAt = nil
        return true
    }

    private func insertDerivedEvent(_ draft: DerivedEventDraft, preserving prior: MemoryEvent? = nil) {
        let userMetadata = prior?.contextCard?.metadata.filter { $0.key == "userNote" || $0.key == "contacts" } ?? []
        let event = MemoryEvent(
            occurredAt: draft.occurredAt,
            source: draft.source,
            title: draft.title,
            detail: draft.detail,
            context: draft.title,
            contextCard: derivedContextCard(for: draft, preserving: userMetadata),
            symbolName: derivedSymbol(for: draft),
            colorName: draft.source == "workout" ? "green" : "teal",
            confidenceScore: draft.confidenceScore,
            derivedEndedAt: draft.endedAt
        )
        event.includeHealthData = draft.source == "workout" || draft.source == "sleep"
        event.healthSummary = prior?.healthSummary
        event.distanceMeters = draft.distanceMeters
        event.workoutRoute = draft.route
        event.place = draft.place.map { Place(name: $0.name, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        event.weatherSnapshot = prior?.weatherSnapshot
        event.photoAttachments = prior?.photoAttachments ?? []
        modelContext.insert(event)
    }

    private func derivedContextCard(
        for draft: DerivedEventDraft,
        preserving userMetadata: [ContextCard.MetadataEntry] = []
    ) -> ContextCard {
        var metadata: [ContextCard.MetadataEntry] = [
            .init(key: "endedAt", value: ISO8601DateFormatter().string(from: draft.endedAt))
        ]
        if let motion = draft.motion {
            metadata.append(.init(key: "motion", value: motion.rawValue))
        }
        if let bluetoothContext = draft.bluetoothContext {
            metadata.append(.init(key: "bluetoothContext", value: bluetoothContext.rawValue))
        }
        if let media = draft.mediaNowPlaying {
            metadata.append(.init(key: "mediaNowPlaying", value: media.displayText))
        }
        metadata.append(contentsOf: userMetadata)
        return ContextCard(source: draft.source, category: "derived", summary: draft.detail ?? draft.title, metadata: metadata)
    }

    private func derivedSymbol(for draft: DerivedEventDraft) -> String {
        if draft.source == "workout" { return "figure.run" }
        if draft.title == "Stop" { return "parkingsign.circle" }
        return draft.motion == .walking ? "figure.walk" : "car.fill"
    }

    func syncCalendarEvents(_ imported: [TimelineCalendarImportEvent], for day: Date, attendeeLocationSharingEnabled: Bool) throws {
        let calendar = Calendar.current
        var existing = fetchAll().filter {
            $0.source == "calendar" && ($0.occurredAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
        }

        // Collapses duplicates that share the same occurrence (start time + title) but lost their externalSourceID
        // link across a sync round-trip — e.g. each device/reinstall previously pushed the same calendar item
        // under its own random id, producing separate backend rows that all pull back down as separate events.
        var survivorByOccurrence: [String: MemoryEvent] = [:]
        var occurrenceDuplicates: [MemoryEvent] = []
        for event in existing.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let occurredAt = event.occurredAt, let title = event.title else { continue }
            let key = "\(occurredAt.timeIntervalSince1970)|\(title)"
            if let survivor = survivorByOccurrence[key] {
                if survivor.externalSourceID == nil, let externalSourceID = event.externalSourceID {
                    survivor.externalSourceID = externalSourceID
                }
                occurrenceDuplicates.append(event)
            } else {
                survivorByOccurrence[key] = event
            }
        }
        for duplicate in occurrenceDuplicates {
            removeCalendarEvent(duplicate)
        }
        existing.removeAll { candidate in occurrenceDuplicates.contains { $0 === candidate } }

        var existingByExternalID: [String: MemoryEvent] = [:]
        var duplicateExisting: [MemoryEvent] = []
        for event in existing {
            guard let externalSourceID = event.externalSourceID else { continue }
            if existingByExternalID[externalSourceID] == nil {
                existingByExternalID[externalSourceID] = event
            } else {
                duplicateExisting.append(event)
            }
        }

        // Keep one event per external ID to avoid dictionary collisions on subsequent syncs.
        for duplicate in duplicateExisting {
            removeCalendarEvent(duplicate)
        }
        existing.removeAll { candidate in duplicateExisting.contains { $0 === candidate } }

        var importedByExternalID: [String: TimelineCalendarImportEvent] = [:]
        for item in imported {
            importedByExternalID[item.externalID] = item
        }

        let normalizedImported = importedByExternalID.values.sorted { $0.startsAt < $1.startsAt }
        let importedIDs = Set(importedByExternalID.keys)
        for stale in existing where !(stale.externalSourceID.map(importedIDs.contains) ?? false) {
            removeCalendarEvent(stale)
        }

        for item in normalizedImported {
            if let event = existingByExternalID[item.externalID] {
                var changed = updateCalendarEvent(event, with: item)
                if event.calendarSyncEligible != attendeeLocationSharingEnabled {
                    event.calendarSyncEligible = attendeeLocationSharingEnabled
                    if !attendeeLocationSharingEnabled && event.syncedToBackendAt != nil {
                        // Sharing was revoked after this event had already synced: push a tombstone to remove it server-side.
                        event.isDeleted = true
                        event.backendVersion = max(1, event.backendVersion + 1)
                        event.syncedToBackendAt = nil
                    }
                    changed = true
                }
                if changed {
                    event.updatedAt = Date()
                }
                continue
            }

            let event = MemoryEvent(
                externalSourceID: item.externalID,
                isReadOnlySource: true,
                occurredAt: item.startsAt,
                source: "calendar",
                title: item.title,
                detail: item.locationName,
                context: formatTimeRange(start: item.startsAt, end: item.endsAt),
                contextCard: calendarContextCard(from: item),
                symbolName: "calendar",
                colorName: "orange",
                calendarSyncEligible: attendeeLocationSharingEnabled
            )
            applyCalendarEnrichment(from: item, to: event)
            modelContext.insert(event)
            existingByExternalID[item.externalID] = event
        }

        if modelContext.hasChanges {
            try modelContext.save()
            NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
        }
    }

    /// Removes a calendar event locally, tombstoning it first if it had already synced so the deletion propagates.
    private func removeCalendarEvent(_ event: MemoryEvent) {
        guard event.calendarSyncEligible, event.syncedToBackendAt != nil else {
            modelContext.delete(event)
            return
        }
        event.isDeleted = true
        event.updatedAt = Date()
        event.backendVersion = max(1, event.backendVersion + 1)
        event.syncedToBackendAt = nil
    }

    func delete(event: MemoryEvent) throws {
        if event.source == "calendar" {
            modelContext.delete(event)
        } else {
            event.isDeleted = true
            event.updatedAt = Date()
            event.backendVersion = max(1, event.backendVersion + 1)
            event.syncedToBackendAt = nil
        }
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    func update(event: MemoryEvent) throws {
        // For now, assume the event object is already modified in-place.
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    func linkEvent(_ eventID: UUID, to linkedEventIDs: [UUID]) throws {
        let linked = Set(linkedEventIDs.filter { $0 != eventID })
        guard !linked.isEmpty else { return }
        let events = fetchAll()
        guard let target = events.first(where: { $0.id == eventID }) else { return }
        target.linkedEventIDs = Array(Set(target.linkedEventIDs).union(linked))
        target.updatedAt = Date()
        if modelContext.hasChanges {
            try modelContext.save()
            NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
        }
    }

    func applyRetentionPolicy(for consent: Tier1ConsentState) throws {
        let events = fetchAll()
        for event in events {
            if event.source == "calendar" && !consent.calendarImportEnabled {
                modelContext.delete(event)
                continue
            }

            if !consent.calendarAttendeesAndLocationsEnabled && event.source == "calendar" {
                event.detail = nil
                event.place = nil
                event.weatherSnapshot = nil
                scrubMetadata(keys: ["attendees", "location", "weather"], from: event)
            }

            if !consent.locationCaptureEnabled && event.source != "calendar" {
                event.place = nil
                scrubMetadata(keys: ["visit"], from: event)
            }

            if !consent.weatherSnapshotsEnabled {
                event.weatherSnapshot = nil
                scrubMetadata(keys: ["weather"], from: event)
            }

            if !consent.motionAttachmentEnabled {
                scrubMetadata(keys: ["motion"], from: event)
            }

            if !consent.timeSemanticsEnabled {
                scrubMetadata(keys: ["timeSemantics"], from: event)
            }

            if consent.healthConsent.enabledMetrics.isEmpty {
                event.healthSummary = nil
            } else if let summary = event.healthSummary {
                let allowed = consent.healthConsent.enabledMetrics
                let retainedEntries = summary.entries.filter { allowed.contains($0.metric) }
                if retainedEntries.isEmpty {
                    event.healthSummary = nil
                } else if retainedEntries.count != summary.entries.count {
                    event.healthSummary = HealthSummary(capturedAt: summary.capturedAt, entries: retainedEntries)
                }
            }

            if !consent.photoAttachmentEnabled {
                event.photoAttachments = []
            }

            if !consent.voiceTranscriptionEnabled {
                event.extractionReview = nil
                scrubMetadata(keys: ["bluetoothContext", "extractedPerson", "extractedInteraction", "transcriptConfidence"], from: event)
            }

            if !consent.bluetoothContextEnabled {
                scrubMetadata(keys: ["bluetoothContext"], from: event)
            }

            if !consent.contactsResolutionEnabled {
                event.contactMoment?.resolvedContactIdentifier = nil
            }

            event.updatedAt = Date()
        }

        if modelContext.hasChanges {
            try modelContext.save()
            NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
        }
    }

    func fetchUnsyncedEvents() -> [MemoryEvent] {
        fetchStoredEvents().filter { (!$0.isReadOnlySource || $0.calendarSyncEligible) && $0.syncedToBackendAt == nil }
    }

    func markSynced(eventId: String, version: Int, syncedAt: Date) throws {
        guard let event = findStoredEvent(eventId: eventId) else { return }
        event.backendEventId = eventId
        event.backendVersion = version
        event.syncedToBackendAt = syncedAt
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    func applyConflict(eventId: String, serverVersion: Int, strategy: String) throws {
        guard let event = findStoredEvent(eventId: eventId) else { return }
        print("Sync conflict for \(eventId): strategy=\(strategy), serverVersion=\(serverVersion)")
        event.backendEventId = eventId
        if strategy.lowercased().contains("server") {
            event.backendVersion = serverVersion
            event.syncedToBackendAt = Date()
        } else {
            event.backendVersion = max(event.backendVersion, serverVersion)
            event.syncedToBackendAt = nil
        }
        try modelContext.save()
    }

    func mergePulledEvents(_ events: [PullEventResponse]) throws {
        var changed = false
        for remote in events {
            guard let local = findStoredEvent(eventId: remote.eventId) else {
                modelContext.insert(makeLocalEvent(from: remote))
                changed = true
                continue
            }

            guard remote.version >= local.backendVersion else { continue }
            guard remote.updatedAt >= local.updatedAt || local.syncedToBackendAt != nil else { continue }
            apply(remote, to: local)
            changed = true
        }

        guard changed else { return }
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    func makePushRequest(for event: MemoryEvent) -> PushEventRequest {
        let contextData = event.syncContextData
        let payload = event.defaultEncryptedPayload
        let hash = event.defaultPayloadHash
        let eventId: String
        if event.source == "calendar", let externalSourceID = event.externalSourceID {
            // Same calendar occurrence must upsert the same backend row no matter which device/reinstall pushes it.
            eventId = Self.stableCalendarEventId(for: externalSourceID)
        } else {
            eventId = event.backendEventId ?? event.id.uuidString
        }
        return PushEventRequest(
            eventId: eventId,
            version: max(event.backendVersion, 1),
            occurredAt: event.occurredAt ?? event.updatedAt,
            source: event.source ?? "unknown",
            title: event.title,
            detail: event.detail,
            searchText: event.context,
            contextData: contextData.isEmpty ? nil : contextData,
            encryptedPayload: payload,
            payloadHash: hash,
            isDeleted: event.isDeleted
        )
    }

    private func fetchStoredEvents() -> [MemoryEvent] {
        (try? modelContext.fetch(FetchDescriptor<MemoryEvent>())) ?? []
    }

    private func findStoredEvent(eventId: String) -> MemoryEvent? {
        let events = fetchStoredEvents()
        if let match = events.first(where: { $0.backendEventId == eventId || $0.id.uuidString == eventId }) {
            return match
        }
        // Calendar events may have been pushed under a stable hash rather than their local id/backendEventId.
        return events.first {
            $0.source == "calendar" && $0.externalSourceID.map(Self.stableCalendarEventId) == eventId
        }
    }

    private static func stableCalendarEventId(for externalSourceID: String) -> String {
        SHA256.hash(data: Data("calendar:\(externalSourceID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeLocalEvent(from remote: PullEventResponse) -> MemoryEvent {
        let event = MemoryEvent(occurredAt: remote.occurredAt, source: remote.source, title: remote.title, detail: remote.detail, context: remote.searchText, backendEventId: remote.eventId, backendVersion: remote.version, syncedToBackendAt: remote.updatedAt, payloadHash: remote.payloadHash, encryptedPayload: remote.encryptedPayload, isDeleted: remote.isDeleted)
        event.createdAt = remote.createdAt
        event.updatedAt = remote.updatedAt
        Self.apply(contextData: remote.contextData, to: event)
        return event
    }

    private func apply(_ remote: PullEventResponse, to event: MemoryEvent) {
        event.backendEventId = remote.eventId
        event.backendVersion = remote.version
        event.occurredAt = remote.occurredAt
        event.source = remote.source
        event.title = remote.title
        event.detail = remote.detail
        event.context = remote.searchText
        Self.apply(contextData: remote.contextData, to: event)
        event.payloadHash = remote.payloadHash
        event.encryptedPayload = remote.encryptedPayload
        event.isDeleted = remote.isDeleted
        event.createdAt = remote.createdAt
        event.updatedAt = remote.updatedAt
        event.syncedToBackendAt = remote.updatedAt
    }

    static func apply(contextData: SyncEventContextData?, to event: MemoryEvent) {
        guard let contextData else { return }

        if let externalSourceID = contextData.externalSourceID {
            event.externalSourceID = externalSourceID
            if event.source == "calendar" {
                event.isReadOnlySource = true
            }
        }

        event.place = contextData.place.map {
            Place(name: $0.name, latitude: $0.latitude, longitude: $0.longitude)
        }
        event.weatherSnapshot = contextData.weather.map {
            WeatherSnapshot(observedAt: $0.observedAt, condition: $0.condition, temperatureC: $0.temperatureC)
        }
        event.healthSummary = contextData.healthSummary.map { entries in
            HealthSummary(
                capturedAt: Date(),
                entries: entries.compactMap { entry in
                    Tier1HealthMetric(rawValue: entry.metric).map { .init(metric: $0, value: entry.value) }
                }
            )
        }
        event.includeHealthData = (event.source == "workout" || event.source == "sleep")
            ? true
            : (contextData.includeHealthData ?? false)
        event.distanceMeters = contextData.distanceMeters
        event.workoutRoute = contextData.workoutRoute.map { route in
            WorkoutRoute(coordinates: route.coordinates.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
        }

        var card = event.contextCard ?? ContextCard(
            source: event.source ?? "unknown",
            category: "moment",
            summary: event.title ?? ""
        )
        card.metadata.removeAll { $0.key == "motion" || $0.key == "bluetoothContext" || $0.key == "mediaNowPlaying" || $0.key == "timeSemantics" || $0.key == "contacts" || $0.key == "userNote" || $0.key == "endedAt" || $0.key == "includeHealthData" }
        if let includeHealthData = contextData.includeHealthData {
            card.metadata.append(.init(key: "includeHealthData", value: String(includeHealthData)))
        }
        if let motion = contextData.motion {
            card.metadata.append(.init(key: "motion", value: motion))
        }
        if let bluetoothContext = contextData.bluetoothContext {
            card.metadata.append(.init(key: "bluetoothContext", value: bluetoothContext))
        }
        if let media = contextData.mediaNowPlaying {
            card.metadata.append(.init(key: "mediaNowPlaying", value: MediaNowPlaying(title: media.title, artist: media.artist, albumTitle: media.albumTitle, source: media.source).displayText))
        }
        if let timeSemantics = contextData.timeSemantics, !timeSemantics.isEmpty {
            card.metadata.append(.init(key: "timeSemantics", value: timeSemantics.joined(separator: ",")))
        }
        if let contacts = contextData.contacts, !contacts.isEmpty {
            card.metadata.append(.init(key: "contacts", value: contacts.joined(separator: ",")))
        }
        if let userNote = contextData.userNote, !userNote.isEmpty {
            card.metadata.append(.init(key: "userNote", value: userNote))
        }
        if let endedAt = contextData.endedAt {
            card.metadata.append(.init(key: "endedAt", value: ISO8601DateFormatter().string(from: endedAt)))
            if event.contactMoment == nil {
                event.derivedEndedAt = endedAt
            }
        }
        event.contextCard = card
        event.photoAttachments = (contextData.photoReferences ?? []).map {
            PhotoAttachment(
                assetIdentifier: $0.assetIdentifier,
                filename: $0.filename ?? $0.assetIdentifier,
                addedAt: $0.addedAt
            )
        }
    }

    private func apply(enrichment: ContextEnrichment?, to event: MemoryEvent) {
        guard let enrichment else { return }

        var metadata = event.contextCard?.metadata ?? []
        if let visit = enrichment.visit {
            event.place = Place(name: visit.name, latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
            metadata.append(.init(key: "visit", value: visit.name))
        }
        if let weather = enrichment.weather {
            event.weatherSnapshot = WeatherSnapshot(observedAt: weather.observedAt, condition: weather.condition, temperatureC: weather.temperatureC)
            metadata.append(.init(key: "weather", value: "\(weather.condition), \(Int(weather.temperatureC.rounded()))C"))
        }
        if let motion = enrichment.motionState {
            metadata.append(.init(key: "motion", value: motion.rawValue))
        }
        if let healthSummary = enrichment.healthSummary, !healthSummary.isEmpty {
            event.healthSummary = healthSummary
        }
        if !enrichment.timeSemanticLabels.isEmpty {
            metadata.append(.init(key: "timeSemantics", value: enrichment.timeSemanticLabels.joined(separator: ",")))
        }

        if var card = event.contextCard {
            card.metadata = metadata
            event.contextCard = card
        }
    }

    private func scrubMetadata(keys: Set<String>, from event: MemoryEvent) {
        guard var card = event.contextCard else { return }
        card.metadata.removeAll { keys.contains($0.key) }
        event.contextCard = card
    }

    private func calendarContextCard(from item: TimelineCalendarImportEvent) -> ContextCard {
        var metadata: [ContextCard.MetadataEntry] = []

        if !item.attendeeNames.isEmpty {
            metadata.append(.init(key: "attendees", value: item.attendeeNames.joined(separator: ", ")))
        }
        if let location = item.locationName, !location.isEmpty {
            metadata.append(.init(key: "location", value: location))
        }
        if let weather = item.weather {
            metadata.append(.init(key: "weather", value: "\(weather.condition), \(Int(weather.temperatureC.rounded()))C"))
        }
        if !item.timeSemanticLabels.isEmpty {
            metadata.append(.init(key: "timeSemantics", value: item.timeSemanticLabels.joined(separator: ",")))
        }

        return ContextCard(
            source: "calendar",
            category: "schedule",
            summary: item.title,
            metadata: metadata
        )
    }

    private func formatTimeRange(start: Date, end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: start, to: end)
    }

    private func updateCalendarEvent(_ event: MemoryEvent, with item: TimelineCalendarImportEvent) -> Bool {
        var hasChanges = false

        if event.occurredAt != item.startsAt {
            event.occurredAt = item.startsAt
            hasChanges = true
        }
        if event.title != item.title {
            event.title = item.title
            hasChanges = true
        }
        if event.detail != item.locationName {
            event.detail = item.locationName
            hasChanges = true
        }

        let timeRange = formatTimeRange(start: item.startsAt, end: item.endsAt)
        if event.context != timeRange {
            event.context = timeRange
            hasChanges = true
        }

        let nextCard = calendarContextCard(from: item)
        if event.contextCard != nextCard {
            event.contextCard = nextCard
            hasChanges = true
        }

        if applyCalendarEnrichment(from: item, to: event) {
            hasChanges = true
        }

        return hasChanges
    }

    private func applyCalendarEnrichment(from item: TimelineCalendarImportEvent, to event: MemoryEvent) -> Bool {
        var hasChanges = false

        if let coordinate = item.locationCoordinate {
            if let place = event.place {
                let nextName = item.locationName ?? place.name
                if place.name != nextName {
                    place.name = nextName
                    hasChanges = true
                }
                if place.latitude != coordinate.latitude {
                    place.latitude = coordinate.latitude
                    hasChanges = true
                }
                if place.longitude != coordinate.longitude {
                    place.longitude = coordinate.longitude
                    hasChanges = true
                }
            } else {
                event.place = Place(name: item.locationName ?? "Calendar location", latitude: coordinate.latitude, longitude: coordinate.longitude)
                hasChanges = true
            }
        } else if event.place != nil {
            event.place = nil
            hasChanges = true
        }

        if let weather = item.weather {
            if let snapshot = event.weatherSnapshot {
                if snapshot.observedAt != weather.observedAt {
                    snapshot.observedAt = weather.observedAt
                    hasChanges = true
                }
                if snapshot.condition != weather.condition {
                    snapshot.condition = weather.condition
                    hasChanges = true
                }
                if snapshot.temperatureC != weather.temperatureC {
                    snapshot.temperatureC = weather.temperatureC
                    hasChanges = true
                }
            } else {
                event.weatherSnapshot = WeatherSnapshot(observedAt: weather.observedAt, condition: weather.condition, temperatureC: weather.temperatureC)
                hasChanges = true
            }
        } else if event.weatherSnapshot != nil {
            event.weatherSnapshot = nil
            hasChanges = true
        }

        return hasChanges
    }
}

private struct LocalSyncPayload: Codable {
    let occurredAt: Date?
    let source: String?
    let title: String?
    let detail: String?
    let context: String?
    let contextData: SyncEventContextData
}

private extension MemoryEvent {
    var syncContextData: SyncEventContextData {
        let metadataByKey = Dictionary(
            (contextCard?.metadata ?? []).map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let timeSemantics = metadataByKey["timeSemantics"]?
            .split(separator: ",")
            .map(String.init)
        let photoReferences = photoAttachments.compactMap { attachment -> SyncPhotoReference? in
            guard let assetIdentifier = attachment.assetIdentifier else { return nil }
            return SyncPhotoReference(
                assetIdentifier: assetIdentifier,
                filename: attachment.filename,
                addedAt: attachment.addedAt
            )
        }

        return SyncEventContextData(
            place: place.map { SyncPlaceData(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) },
            weather: weatherSnapshot.map {
                SyncWeatherData(observedAt: $0.observedAt, condition: $0.condition, temperatureC: $0.temperatureC)
            },
            motion: metadataByKey["motion"],
            bluetoothContext: metadataByKey["bluetoothContext"],
            timeSemantics: timeSemantics,
            photoReferences: photoReferences,
            contacts: contactMoment?.contactNames.isEmpty == false
                ? contactMoment?.contactNames
                : metadataByKey["contacts"]?.split(separator: ",").map(String.init),
            userNote: metadataByKey["userNote"],
            endedAt: contactMoment?.endedAt ?? derivedEndedAt,
            includeHealthData: includeHealthData,
            healthSummary: healthSummary?.entries.map { SyncHealthEntryData(metric: $0.metric.rawValue, value: $0.value) },
            distanceMeters: distanceMeters,
            workoutRoute: workoutRoute.map { route in
                SyncWorkoutRouteData(coordinates: route.coordinates.map { SyncGeoCoordinateData(latitude: $0.latitude, longitude: $0.longitude) })
            },
            mediaNowPlaying: metadataByKey["mediaNowPlaying"].map {
                SyncMediaNowPlayingData(title: $0, artist: nil, albumTitle: nil, source: nil)
            },
            externalSourceID: externalSourceID
        )
    }

    var defaultEncryptedPayload: String {
        let payload = LocalSyncPayload(
            occurredAt: occurredAt,
            source: source,
            title: title,
            detail: detail,
            context: context,
            contextData: syncContextData
        )
        guard let data = try? JSONEncoder.iso8601.encode(payload) else { return "" }
        return data.base64EncodedString()
    }

    var defaultPayloadHash: String {
        let data = Data(defaultEncryptedPayload.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
