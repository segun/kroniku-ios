import Foundation
@testable import Kroniku

final class MockMemoryRepository: MemoryRepositoryProtocol {
    private(set) var events: [MemoryEvent] = []

    func fetchAll() -> [MemoryEvent] {
        return events.sorted { (a, b) in
            (a.occurredAt ?? Date.distantPast) > (b.occurredAt ?? Date.distantPast)
        }
    }

    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String = "typed", contextEnrichment: ContextEnrichment? = nil, photoAttachments: [PhotoAttachment] = [], resolvedContactIdentifier: String? = nil, extractionReview: Tier2ExtractionReview? = nil, bluetoothContext: BluetoothContextKind? = nil, confidenceScore: Double? = nil, linkedEventIDs: [UUID] = [], contactNames: [String] = [], resolvedContactIdentifiers: [String] = [], endedAt: Date? = nil) throws {
        let trimmedPersonName = personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactNames = contactNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        guard !(trimmedNote.isEmpty && (trimmedPersonName?.isEmpty ?? true) && trimmedContactNames.isEmpty) else {
            throw MemoryRepositoryError.emptyContactMoment
        }

        guard let interaction = Interaction(rawValue: interactionType) else {
            throw MemoryRepositoryError.invalidInteraction
        }

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

        let cm = ContactMoment(personName: trimmedPersonName?.isEmpty == true ? nil : trimmedPersonName, interactionType: interaction.rawValue, occurredAt: occurredAt, endedAt: endedAt, note: trimmedNote, captureMethod: captureMethod, resolvedContactIdentifier: resolvedContactIdentifier, contactNames: trimmedContactNames, resolvedContactIdentifiers: resolvedContactIdentifiers)
        let me = MemoryEvent(
            occurredAt: occurredAt,
            source: "contactMoment",
            title: cm.note,
            detail: trimmedContactNames.isEmpty ? cm.personName : trimmedContactNames.joined(separator: ", "),
            context: interaction.title,
            contextCard: ContextCard(
                source: "contactMoment",
                category: "moment",
                summary: trimmedNote,
                metadata: metadata
            ),
            symbolName: interaction.symbol,
            colorName: "indigo",
            extractionReview: extractionReview,
            photoAttachments: photoAttachments
        )
        me.confidenceScore = confidenceScore
        me.linkedEventIDs = linkedEventIDs
        if let enrichment = contextEnrichment {
            if let visit = enrichment.visit {
                me.place = Place(name: visit.name, latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
            }
            if let weather = enrichment.weather {
                me.weatherSnapshot = WeatherSnapshot(observedAt: weather.observedAt, condition: weather.condition, temperatureC: weather.temperatureC)
            }
            if let healthSummary = enrichment.healthSummary {
                me.healthSummary = healthSummary
            }
            if !enrichment.timeSemanticLabels.isEmpty {
                me.contextCard?.metadata.append(.init(key: "timeSemantics", value: enrichment.timeSemanticLabels.joined(separator: ",")))
            }
            if let motionState = enrichment.motionState {
                me.contextCard?.metadata.append(.init(key: "motion", value: motionState.rawValue))
            }
        }
        cm.memoryEvent = me
        me.contactMoment = cm
        events.append(me)
    }

    func syncCalendarEvents(_ imported: [TimelineCalendarImportEvent], for day: Date) throws {
        let calendar = Calendar.current
        let importedIDs = Set(imported.map(\.externalID))
        events.removeAll {
            $0.source == "calendar" &&
            ($0.occurredAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false) &&
            !(($0.externalSourceID).map(importedIDs.contains) ?? false)
        }

        for item in imported {
            if let index = events.firstIndex(where: {
                $0.source == "calendar" &&
                $0.externalSourceID == item.externalID &&
                ($0.occurredAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
            }) {
                events[index].title = item.title
                events[index].occurredAt = item.startsAt
                events[index].detail = item.locationName
                events[index].context = "calendar"
            } else {
                events.append(MemoryEvent(
                    externalSourceID: item.externalID,
                    isReadOnlySource: true,
                    occurredAt: item.startsAt,
                    source: "calendar",
                    title: item.title,
                    detail: item.locationName,
                    context: "calendar",
                    contextCard: ContextCard(source: "calendar", category: "schedule", summary: item.title),
                    symbolName: "calendar",
                    colorName: "orange"
                ))
            }
        }
    }

    func delete(event: MemoryEvent) throws {
        events.removeAll { $0.id == event.id }
    }

    func update(event: MemoryEvent) throws {
        // in-memory objects are mutated in place; nothing to do
    }

    func linkEvent(_ eventID: UUID, to linkedEventIDs: [UUID]) throws {
        guard let event = events.first(where: { $0.id == eventID }) else { return }
        let linked = Set(linkedEventIDs.filter { $0 != eventID })
        event.linkedEventIDs = Array(Set(event.linkedEventIDs).union(linked))
    }

    func applyRetentionPolicy(for consent: Tier1ConsentState) throws {
        events.removeAll { $0.source == "calendar" && !consent.calendarImportEnabled }
        for event in events {
            if !consent.calendarAttendeesAndLocationsEnabled && event.source == "calendar" {
                event.detail = nil
                event.place = nil
                event.weatherSnapshot = nil
                event.contextCard?.metadata.removeAll { ["attendees", "location", "weather"].contains($0.key) }
            }
            if !consent.locationCaptureEnabled && event.source != "calendar" {
                event.place = nil
                event.contextCard?.metadata.removeAll { $0.key == "visit" }
            }
            if !consent.weatherSnapshotsEnabled {
                event.weatherSnapshot = nil
                event.contextCard?.metadata.removeAll { $0.key == "weather" }
            }
            if !consent.motionAttachmentEnabled {
                event.contextCard?.metadata.removeAll { $0.key == "motion" }
            }
            if !consent.timeSemanticsEnabled {
                event.contextCard?.metadata.removeAll { $0.key == "timeSemantics" }
            }
            if !consent.healthConsent.isEnabled {
                event.healthSummary = nil
            }
            if !consent.photoAttachmentEnabled {
                event.photoAttachments = []
            }
            if !consent.voiceTranscriptionEnabled {
                event.extractionReview = nil
                event.contextCard?.metadata.removeAll { ["bluetoothContext", "transcriptConfidence", "extractedPerson", "extractedInteraction"].contains($0.key) }
            }
            if !consent.bluetoothContextEnabled {
                event.contextCard?.metadata.removeAll { $0.key == "bluetoothContext" }
            }
            if !consent.contactsResolutionEnabled {
                event.contactMoment?.resolvedContactIdentifier = nil
            }
        }
    }

    func fetchUnsyncedEvents() -> [MemoryEvent] {
        events.filter { !$0.isReadOnlySource && !$0.isDeleted && $0.syncedToBackendAt == nil }
    }

    func markSynced(eventId: String, version: Int, syncedAt: Date) throws {
        guard let event = events.first(where: { $0.id.uuidString == eventId || $0.backendEventId == eventId }) else { return }
        event.backendEventId = eventId
        event.backendVersion = version
        event.syncedToBackendAt = syncedAt
    }

    func applyConflict(eventId: String, serverVersion: Int, strategy: String) throws {
        guard let event = events.first(where: { $0.id.uuidString == eventId || $0.backendEventId == eventId }) else { return }
        event.backendVersion = serverVersion
        if strategy.lowercased().contains("server") {
            event.syncedToBackendAt = Date()
        }
    }

    func mergePulledEvents(_ events: [PullEventResponse]) throws {
        for remote in events {
            if let local = self.events.first(where: { $0.backendEventId == remote.eventId }) {
                local.backendVersion = remote.version
                local.updatedAt = remote.updatedAt
                local.isDeleted = remote.isDeleted
            } else {
                self.events.append(MemoryEvent(occurredAt: remote.occurredAt, source: remote.source, title: remote.title, detail: remote.detail, context: remote.searchText, backendEventId: remote.eventId, backendVersion: remote.version, syncedToBackendAt: remote.updatedAt, payloadHash: remote.payloadHash, encryptedPayload: remote.encryptedPayload, isDeleted: remote.isDeleted))
            }
        }
    }

    func makePushRequest(for event: MemoryEvent) -> PushEventRequest {
        PushEventRequest(eventId: event.backendEventId ?? event.id.uuidString, version: max(event.backendVersion, 1), occurredAt: event.occurredAt ?? event.updatedAt, source: event.source ?? "unknown", title: event.title, detail: event.detail, searchText: event.context, contextData: nil, encryptedPayload: event.encryptedPayload ?? "", payloadHash: event.payloadHash ?? "", isDeleted: event.isDeleted)
    }
}
