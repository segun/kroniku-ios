import Foundation
@testable import Kroniku

final class MockMemoryRepository: MemoryRepositoryProtocol {
    private(set) var events: [MemoryEvent] = []

    func fetchAll() -> [MemoryEvent] {
        return events.sorted { (a, b) in
            (a.occurredAt ?? Date.distantPast) > (b.occurredAt ?? Date.distantPast)
        }
    }

    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String = "typed") throws {
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
        cm.memoryEvent = me
        me.contactMoment = cm
        events.append(me)
    }

    func delete(event: MemoryEvent) throws {
        events.removeAll { $0.id == event.id }
    }

    func update(event: MemoryEvent) throws {
        // in-memory objects are mutated in place; nothing to do
    }
}
