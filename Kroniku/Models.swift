import Foundation
import SwiftData

enum Tier1HealthMetric: String, Codable, Hashable, CaseIterable, Identifiable {
    case steps
    case heartRate
    case sleep
    case mindfulMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steps:
            return "Steps"
        case .heartRate:
            return "Heart rate"
        case .sleep:
            return "Sleep"
        case .mindfulMinutes:
            return "Mindful minutes"
        }
    }
}

struct Tier1HealthConsent: Codable, Hashable {
    var enabledMetrics: Set<Tier1HealthMetric> = []

    var isEnabled: Bool {
        !enabledMetrics.isEmpty
    }
}

struct HealthSummary: Codable, Hashable {
    struct Entry: Codable, Hashable, Identifiable {
        let id: UUID
        var metric: Tier1HealthMetric
        var value: String

        init(id: UUID = UUID(), metric: Tier1HealthMetric, value: String) {
            self.id = id
            self.metric = metric
            self.value = value
        }
    }

    var capturedAt: Date
    var entries: [Entry]

    var isEmpty: Bool {
        entries.isEmpty
    }
}

struct PhotoAttachment: Codable, Hashable, Identifiable {
    let id: UUID
    var filename: String
    var imageData: Data
    var addedAt: Date

    init(id: UUID = UUID(), filename: String, imageData: Data, addedAt: Date = Date()) {
        self.id = id
        self.filename = filename
        self.imageData = imageData
        self.addedAt = addedAt
    }
}

enum PermissionState: String, Codable, Hashable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum MotionState: String, Codable, Hashable {
    case driving
    case walking
    case running
    case cycling
    case stationary
}

struct GeoCoordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double
}

struct VisitSnapshot: Codable, Hashable {
    var name: String
    var coordinate: GeoCoordinate
    var capturedAt: Date
}

struct WeatherReading: Codable, Hashable {
    var observedAt: Date
    var condition: String
    var temperatureC: Double
}

struct TimelineCalendarImportEvent: Codable, Hashable {
    var externalID: String
    var title: String
    var startsAt: Date
    var endsAt: Date
    var locationName: String?
    var locationCoordinate: GeoCoordinate?
    var weather: WeatherReading?
    var attendeeNames: [String]
    var timeSemanticLabels: [String]
}

struct ContextEnrichment: Codable, Hashable {
    var visit: VisitSnapshot?
    var weather: WeatherReading?
    var motionState: MotionState?
    var healthSummary: HealthSummary?
    var timeSemanticLabels: [String]

    init(visit: VisitSnapshot? = nil, weather: WeatherReading? = nil, motionState: MotionState? = nil, healthSummary: HealthSummary? = nil, timeSemanticLabels: [String] = []) {
        self.visit = visit
        self.weather = weather
        self.motionState = motionState
        self.healthSummary = healthSummary
        self.timeSemanticLabels = timeSemanticLabels
    }
}

struct Tier1ConsentState: Codable, Hashable {
    var calendarImportEnabled: Bool = false
    var calendarAttendeesAndLocationsEnabled: Bool = false
    var locationCaptureEnabled: Bool = false
    var weatherSnapshotsEnabled: Bool = false
    var motionAttachmentEnabled: Bool = false
    var healthConsent: Tier1HealthConsent = Tier1HealthConsent()
    var healthAuthorizationState: PermissionState = .notDetermined
    var photoAttachmentEnabled: Bool = false
    var timeSemanticsEnabled: Bool = true
    var hasCompletedOnboarding: Bool = false
    var needsOnboardingResume: Bool = false
    var onboardingPage: Int = 0
}

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
    var externalSourceID: String?
    var isReadOnlySource: Bool = false
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
    var healthSummary: HealthSummary?
    var photoAttachments: [PhotoAttachment]

    init(externalSourceID: String? = nil, isReadOnlySource: Bool = false, occurredAt: Date? = Date(), source: String? = nil, title: String? = nil, detail: String? = nil, context: String? = nil, contextCard: ContextCard? = nil, symbolName: String? = nil, colorName: String? = nil, place: Place? = nil, weatherSnapshot: WeatherSnapshot? = nil, healthSummary: HealthSummary? = nil, photoAttachments: [PhotoAttachment] = []) {
        self.externalSourceID = externalSourceID
        self.isReadOnlySource = isReadOnlySource
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
        self.healthSummary = healthSummary
        self.photoAttachments = photoAttachments
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
