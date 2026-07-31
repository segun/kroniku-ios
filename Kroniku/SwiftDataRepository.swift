import Foundation
import SwiftData
import Combine

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
    func addContactMoment(personName: String?, interactionType: String, occurredAt: Date, note: String, captureMethod: String) throws
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
            colorName: "indigo"
        )
        cm.memoryEvent = me
        me.contactMoment = cm

        modelContext.insert(cm)
        modelContext.insert(me)

        try modelContext.save()

        NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
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
}
