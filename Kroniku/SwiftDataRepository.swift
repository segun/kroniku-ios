import Foundation
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
    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String, contextEnrichment: ContextEnrichment?, photoAttachments: [PhotoAttachment]) throws
    func syncCalendarEvents(_ imported: [TimelineCalendarImportEvent], for day: Date) throws
    func applyRetentionPolicy(for consent: Tier1ConsentState) throws
    func delete(event: MemoryEvent) throws
    func update(event: MemoryEvent) throws
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
            return try modelContext.fetch(fetchDescriptor)
        } catch {
            print("Repository fetch failed: \(error)")
            return []
        }
    }

    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String = "typed", contextEnrichment: ContextEnrichment? = nil, photoAttachments: [PhotoAttachment] = []) throws {
        let trimmedPersonName = personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !(trimmedNote.isEmpty && (trimmedPersonName?.isEmpty ?? true)) else {
            throw MemoryRepositoryError.emptyContactMoment
        }

        guard let interaction = Interaction(rawValue: interactionType) else {
            throw MemoryRepositoryError.invalidInteraction
        }

        let cm = ContactMoment(personName: trimmedPersonName?.isEmpty == true ? nil : trimmedPersonName, interactionType: interaction.rawValue, occurredAt: occurredAt, note: trimmedNote, captureMethod: captureMethod)
        let contextCard = ContextCard(
            source: "contactMoment",
            category: "interaction",
            summary: trimmedNote,
            metadata: [
                .init(key: "interactionType", value: interaction.rawValue),
                .init(key: "captureMethod", value: captureMethod)
            ]
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
            photoAttachments: photoAttachments
        )

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
        if let cm = event.contactMoment {
            modelContext.delete(cm)
        }
        modelContext.delete(event)
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
    }

    func update(event: MemoryEvent) throws {
        // For now, assume the event object is already modified in-place.
        try modelContext.save()
        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
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

            event.updatedAt = Date()
        }

        if modelContext.hasChanges {
            try modelContext.save()
            NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
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
