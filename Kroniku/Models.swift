import Foundation
import SwiftData

// Extensible context card metadata attached to a memory event.
struct ContextCard: Codable, Hashable {
    struct MetadataEntry: Codable, Hashable, Identifiable {
        let id: UUID
        var key: String
        var value: String

        init(id: UUID = UUID(), key: String, value: String) {
            self.id = id
            self.key = key
            self.value = value
        }
    }

    var source: String
    var category: String
    var summary: String
    var metadata: [MetadataEntry]

    init(source: String, category: String, summary: String, metadata: [MetadataEntry] = []) {
        self.source = source
        self.category = category
        self.summary = summary
        self.metadata = metadata
    }
}

@Model
final class MemoryEvent: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var occurredAt: Date?
    var source: String?
    var title: String?
    var detail: String?
    var context: String?
    var contextCard: ContextCard?
    var symbolName: String?
    var colorName: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(inverse: \ContactMoment.memoryEvent) var contactMoment: ContactMoment?
    var place: Place?
    var weatherSnapshot: WeatherSnapshot?

    init(occurredAt: Date? = Date(), source: String? = nil, title: String? = nil, detail: String? = nil, context: String? = nil, contextCard: ContextCard? = nil, symbolName: String? = nil, colorName: String? = nil, place: Place? = nil, weatherSnapshot: WeatherSnapshot? = nil) {
        self.occurredAt = occurredAt
        self.source = source
        self.title = title
        self.detail = detail
        self.context = context
        self.contextCard = contextCard
        self.symbolName = symbolName
        self.colorName = colorName
        self.place = place
        self.weatherSnapshot = weatherSnapshot
    }
}

@Model
final class ContactMoment: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var personName: String?
    var interactionType: String
    var occurredAt: Date
    var note: String
    var captureMethod: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var memoryEvent: MemoryEvent?

    init(personName: String? = nil, interactionType: String = "call", occurredAt: Date = Date(), note: String = "", captureMethod: String = "typed") {
        self.personName = personName
        self.interactionType = interactionType
        self.occurredAt = occurredAt
        self.note = note
        self.captureMethod = captureMethod
    }
}

@Model
final class Place: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var latitude: Double?
    var longitude: Double?
    @Relationship(deleteRule: .nullify) var memoryEvents: [MemoryEvent]

    init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.memoryEvents = []
    }
}

@Model
final class WeatherSnapshot: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var observedAt: Date
    var condition: String?
    var temperatureC: Double?
    @Relationship(deleteRule: .nullify) var memoryEvents: [MemoryEvent]

    init(observedAt: Date = Date(), condition: String? = nil, temperatureC: Double? = nil) {
        self.observedAt = observedAt
        self.condition = condition
        self.temperatureC = temperatureC
        self.memoryEvents = []
    }
}

// Shared interaction type used by capture and detail UIs.
enum Interaction: String, CaseIterable, Identifiable {
    case call, text, meeting
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .call: return "phone.fill"
        case .text: return "message.fill"
        case .meeting: return "person.2.fill"
        }
    }
}
