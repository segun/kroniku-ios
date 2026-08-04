import Foundation
@testable import Kroniku

final class MockMemoryRepository: MemoryRepositoryProtocol {
    private(set) var events: [MemoryEvent] = []

    func fetchAll() -> [MemoryEvent] {
        return events.sorted { (a, b) in
            (a.occurredAt ?? Date.distantPast) > (b.occurredAt ?? Date.distantPast)
        }
    }

    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String = "typed", contextEnrichment: ContextEnrichment? = nil) throws {
        let trimmedPersonName = personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !(trimmedNote.isEmpty && (trimmedPersonName?.isEmpty ?? true)) else {
            throw MemoryRepositoryError.emptyContactMoment
        }

        guard let interaction = Interaction(rawValue: interactionType) else {
            throw MemoryRepositoryError.invalidInteraction
        }

        let cm = ContactMoment(personName: trimmedPersonName?.isEmpty == true ? nil : trimmedPersonName, interactionType: interaction.rawValue, occurredAt: occurredAt, note: trimmedNote, captureMethod: captureMethod)
        let me = MemoryEvent(
            occurredAt: occurredAt,
            source: "contactMoment",
            title: cm.note,
            detail: cm.personName,
            context: interaction.title,
            contextCard: ContextCard(
                source: "contactMoment",
                category: "interaction",
                summary: trimmedNote,
                metadata: [
                    .init(key: "interactionType", value: interaction.rawValue),
                    .init(key: "captureMethod", value: captureMethod)
                ]
            ),
            symbolName: interaction.symbol,
            colorName: "indigo"
        )
        if let enrichment = contextEnrichment {
            if let visit = enrichment.visit {
                me.place = Place(name: visit.name, latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
            }
            if let weather = enrichment.weather {
                me.weatherSnapshot = WeatherSnapshot(observedAt: weather.observedAt, condition: weather.condition, temperatureC: weather.temperatureC)
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
}
