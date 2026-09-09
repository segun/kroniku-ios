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
    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String, contextEnrichment: ContextEnrichment?, photoAttachments: [PhotoAttachment], resolvedContactIdentifier: String?, extractionReview: Tier2ExtractionReview?, bluetoothContext: BluetoothContextKind?, confidenceScore: Double?, linkedEventIDs: [UUID]) throws
    func syncCalendarEvents(_ imported: [TimelineCalendarImportEvent], for day: Date) throws
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

    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String = "typed", contextEnrichment: ContextEnrichment? = nil, photoAttachments: [PhotoAttachment] = [], resolvedContactIdentifier: String? = nil, extractionReview: Tier2ExtractionReview? = nil, bluetoothContext: BluetoothContextKind? = nil, confidenceScore: Double? = nil, linkedEventIDs: [UUID] = []) throws {
        let trimmedPersonName = personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !(trimmedNote.isEmpty && (trimmedPersonName?.isEmpty ?? true)) else {
            throw MemoryRepositoryError.emptyContactMoment
        }

        guard let interaction = Interaction(rawValue: interactionType) else {
            throw MemoryRepositoryError.invalidInteraction
        }

        let cm = ContactMoment(
            personName: trimmedPersonName?.isEmpty == true ? nil : trimmedPersonName,
            interactionType: interaction.rawValue,
            occurredAt: occurredAt,
            note: trimmedNote,
            captureMethod: captureMethod,
            resolvedContactIdentifier: resolvedContactIdentifier
        )

        var metadata: [ContextCard.MetadataEntry] = [
            .init(key: "interactionType", value: interaction.rawValue),
            .init(key: "captureMethod", value: captureMethod)
        ]
        if let bluetoothContext {
            metadata.append(.init(key: "bluetoothContext", value: bluetoothContext.rawValue))
        }

        let contextCard = ContextCard(
            source: "contactMoment",
            category: "interaction",
            summary: trimmedNote,
            metadata: metadata
        )
        let me = MemoryEvent(
            occurredAt: occurredAt,
            source: "contactMoment",
            title: cm.note,
            detail: cm.personName,
            context: interaction.title,
            contextCard: contextCard,
            symbolName: interaction.symbol,
            colorName: "indigo",
            extractionReview: extractionReview,
            photoAttachments: photoAttachments
        )

        me.linkedEventIDs = linkedEventIDs
        me.confidenceScore = confidenceScore

        apply(enrichment: contextEnrichment, to: me)

        cm.memoryEvent = me
        me.contactMoment = cm

        modelContext.insert(cm)
        modelContext.insert(me)

        try modelContext.save()

        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    func syncCalendarEvents(_ imported: [TimelineCalendarImportEvent], for day: Date) throws {
        let calendar = Calendar.current
        let existing = fetchAll().filter {
            $0.source == "calendar" && ($0.occurredAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
        }
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
            modelContext.delete(duplicate)
        }

        var importedByExternalID: [String: TimelineCalendarImportEvent] = [:]
        for item in imported {
            importedByExternalID[item.externalID] = item
        }

        let normalizedImported = importedByExternalID.values.sorted { $0.startsAt < $1.startsAt }
        let importedIDs = Set(importedByExternalID.keys)
        for stale in existing where !(stale.externalSourceID.map(importedIDs.contains) ?? false) {
            modelContext.delete(stale)
        }

        for item in normalizedImported {
            if let event = existingByExternalID[item.externalID] {
                if updateCalendarEvent(event, with: item) {
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
                colorName: "orange"
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

    func delete(event: MemoryEvent) throws {
        if event.source == "calendar" {
            modelContext.delete(event)
        } else {
            event.isDeleted = true
            event.updatedAt = Date()
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

            if !consent.healthConsent.isEnabled {
                event.healthSummary = nil
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
        fetchStoredEvents().filter { !$0.isReadOnlySource && $0.syncedToBackendAt == nil }
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
        let payload = event.encryptedPayload ?? event.defaultEncryptedPayload
        let hash = event.payloadHash ?? event.defaultPayloadHash
        return PushEventRequest(
            eventId: event.backendEventId ?? event.id.uuidString,
            version: max(event.backendVersion, 1),
            occurredAt: event.occurredAt ?? event.updatedAt,
            source: event.source ?? "unknown",
            title: event.title,
            detail: event.detail,
            searchText: event.context,
            encryptedPayload: payload,
            payloadHash: hash,
            isDeleted: event.isDeleted
        )
    }

    private func fetchStoredEvents() -> [MemoryEvent] {
        (try? modelContext.fetch(FetchDescriptor<MemoryEvent>())) ?? []
    }

    private func findStoredEvent(eventId: String) -> MemoryEvent? {
        fetchStoredEvents().first { $0.backendEventId == eventId || $0.id.uuidString == eventId }
    }

    private func makeLocalEvent(from remote: PullEventResponse) -> MemoryEvent {
        let event = MemoryEvent(occurredAt: remote.occurredAt, source: remote.source, title: remote.title, detail: remote.detail, context: remote.searchText, backendEventId: remote.eventId, backendVersion: remote.version, syncedToBackendAt: remote.updatedAt, payloadHash: remote.payloadHash, encryptedPayload: remote.encryptedPayload, isDeleted: remote.isDeleted)
        event.createdAt = remote.createdAt
        event.updatedAt = remote.updatedAt
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
        event.payloadHash = remote.payloadHash
        event.encryptedPayload = remote.encryptedPayload
        event.isDeleted = remote.isDeleted
        event.createdAt = remote.createdAt
        event.updatedAt = remote.updatedAt
        event.syncedToBackendAt = remote.updatedAt
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
}

private extension MemoryEvent {
    var defaultEncryptedPayload: String {
        let payload = LocalSyncPayload(occurredAt: occurredAt, source: source, title: title, detail: detail, context: context)
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
