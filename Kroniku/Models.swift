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

struct DayPeriodSchedule: Codable, Hashable {
    var morningStartMinutes: Int
    var afternoonStartMinutes: Int
    var earlyEveningStartMinutes: Int
    var nightStartMinutes: Int

    static let `default` = DayPeriodSchedule(
        morningStartMinutes: 6 * 60,
        afternoonStartMinutes: 12 * 60,
        earlyEveningStartMinutes: 16 * 60,
        nightStartMinutes: 21 * 60
    )

    var isValid: Bool {
        morningStartMinutes < afternoonStartMinutes &&
        afternoonStartMinutes < earlyEveningStartMinutes &&
        earlyEveningStartMinutes < nightStartMinutes
    }

    func startMinutes(for period: DayPeriod) -> Int {
        switch period {
        case .morning: return morningStartMinutes
        case .afternoon: return afternoonStartMinutes
        case .earlyEvening: return earlyEveningStartMinutes
        case .night: return nightStartMinutes
        }
    }
}

enum DayPeriod: String, CaseIterable, Codable, Hashable {
    case morning
    case afternoon
    case earlyEvening
    case night

    var title: String {
        switch self {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .earlyEvening: return "Early evening"
        case .night: return "Night"
        }
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
    var assetIdentifier: String?
    var filename: String
    var imageData: Data?
    var addedAt: Date

    init(id: UUID = UUID(), assetIdentifier: String, filename: String, addedAt: Date = Date()) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.filename = filename
        self.imageData = nil
        self.addedAt = addedAt
    }

    init(id: UUID = UUID(), filename: String, imageData: Data, addedAt: Date = Date()) {
        self.id = id
        self.assetIdentifier = nil
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

enum BluetoothContextKind: String, Codable, Hashable {
    case car
    case headphones
    case speaker
}

struct ExtractedEntityConfidence: Codable, Hashable {
    var person: Double
    var interaction: Double
    var timestamp: Double

    var overall: Double {
        max(0, min(1, (person + interaction + timestamp) / 3))
    }
}

struct Tier2ExtractionReview: Codable, Hashable {
    var transcript: String
    var extractedPersonName: String?
    var extractedInteractionType: String?
    var extractedOccurredAt: Date?
    var confidence: ExtractedEntityConfidence
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

struct DerivedEventDraft: Hashable {
    var source: String
    var title: String
    var detail: String?
    var occurredAt: Date
    var endedAt: Date
    var motion: MotionState?
    var place: VisitSnapshot?
    var confidenceScore: Double?
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
    // Optional keeps older UserDefaults consent blobs backward-compatible.
    var dayPeriodSchedule: DayPeriodSchedule?
    // Set whenever the schedule changes locally or is pulled from the backend; used for last-write-wins conflict resolution.
    var dayPeriodScheduleUpdatedAt: Date?
    // True while a local day-period change hasn't been confirmed as pushed to the backend yet.
    var dayPeriodSchedulePendingSync: Bool = false
    var voiceTranscriptionEnabled: Bool = false
    var noteIngestionEnabled: Bool = false
    var contactsResolutionEnabled: Bool = false
    var bluetoothContextEnabled: Bool = false
    // Always-on background significant-location-change/motion/HealthKit-workout monitoring; off by default.
    var backgroundTripDetectionEnabled: Bool = false
    var hasCompletedOnboarding: Bool = false
    var needsOnboardingResume: Bool = false
    var onboardingPage: Int = 0

    var effectiveDayPeriodSchedule: DayPeriodSchedule {
        guard let dayPeriodSchedule, dayPeriodSchedule.isValid else {
            return .default
        }
        return dayPeriodSchedule
    }
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
    var linkedEventIDs: [UUID] = []
    var confidenceScore: Double?
    // End of an occurredAt...endedAt range for system-derived events (e.g. trips/workouts) that have no ContactMoment.
    var derivedEndedAt: Date?
    var backendEventId: String?
    var backendVersion: Int = 0
    var syncedToBackendAt: Date?
    var payloadHash: String?
    var encryptedPayload: String?
    var isDeleted: Bool = false
    // Only meaningful for calendar-sourced events: whether attendee/location sharing consent allows this event to sync.
    var calendarSyncEligible: Bool = false

    @Relationship(inverse: \ContactMoment.memoryEvent) var contactMoment: ContactMoment?
    var place: Place?
    var weatherSnapshot: WeatherSnapshot?
    var healthSummary: HealthSummary?
    var extractionReview: Tier2ExtractionReview?
    var photoAttachments: [PhotoAttachment]

    init(externalSourceID: String? = nil, isReadOnlySource: Bool = false, occurredAt: Date? = Date(), source: String? = nil, title: String? = nil, detail: String? = nil, context: String? = nil, contextCard: ContextCard? = nil, symbolName: String? = nil, colorName: String? = nil, place: Place? = nil, weatherSnapshot: WeatherSnapshot? = nil, healthSummary: HealthSummary? = nil, extractionReview: Tier2ExtractionReview? = nil, photoAttachments: [PhotoAttachment] = [], linkedEventIDs: [UUID] = [], confidenceScore: Double? = nil, derivedEndedAt: Date? = nil, backendEventId: String? = nil, backendVersion: Int = 0, syncedToBackendAt: Date? = nil, payloadHash: String? = nil, encryptedPayload: String? = nil, isDeleted: Bool = false, calendarSyncEligible: Bool = false) {
        self.externalSourceID = externalSourceID
        self.isReadOnlySource = isReadOnlySource
        self.calendarSyncEligible = calendarSyncEligible
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
        self.extractionReview = extractionReview
        self.photoAttachments = photoAttachments
        self.linkedEventIDs = linkedEventIDs
        self.confidenceScore = confidenceScore
        self.derivedEndedAt = derivedEndedAt
        self.backendEventId = backendEventId
        self.backendVersion = backendVersion
        self.syncedToBackendAt = syncedToBackendAt
        self.payloadHash = payloadHash
        self.encryptedPayload = encryptedPayload
        self.isDeleted = isDeleted
    }
}

@Model
final class ContactMoment: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    // Deprecated: kept for backward compatibility with existing data; new captures use contactNames.
    var personName: String?
    var interactionType: String
    var occurredAt: Date
    // End of the occurredAt...endedAt range; nil means no explicit end was recorded.
    var endedAt: Date?
    var note: String
    var captureMethod: String
    // Deprecated: kept for backward compatibility; new captures use resolvedContactIdentifiers.
    var resolvedContactIdentifier: String?
    var contactNames: [String] = []
    var resolvedContactIdentifiers: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var memoryEvent: MemoryEvent?

    init(personName: String? = nil, interactionType: String = "moment", occurredAt: Date = Date(), endedAt: Date? = nil, note: String = "", captureMethod: String = "typed", resolvedContactIdentifier: String? = nil, contactNames: [String] = [], resolvedContactIdentifiers: [String] = []) {
        self.personName = personName
        self.interactionType = interactionType
        self.occurredAt = occurredAt
        self.endedAt = endedAt
        self.note = note
        self.captureMethod = captureMethod
        self.resolvedContactIdentifier = resolvedContactIdentifier
        self.contactNames = contactNames
        self.resolvedContactIdentifiers = resolvedContactIdentifiers
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
// `.moment` is the default for free-form captures; call/text/meeting remain for legacy data.
enum Interaction: String, CaseIterable, Identifiable {
    case moment, call, text, meeting
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .moment: return "sparkles"
        case .call: return "phone.fill"
        case .text: return "message.fill"
        case .meeting: return "person.2.fill"
        }
    }
}
