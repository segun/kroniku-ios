import Foundation

/// Groups raw motion states into the trip types the correlator can open/close; walking and running
/// share the "walk" category so a jog mid-walk doesn't end the trip.
private enum TripMotionCategory: String, Codable {
    case driving
    case walk

    var title: String {
        switch self {
        case .driving: return "Drive"
        case .walk: return "Walk"
        }
    }

    var motionState: MotionState {
        switch self {
        case .driving: return .driving
        case .walk: return .walking
        }
    }

    static func category(for state: MotionState?) -> TripMotionCategory? {
        switch state {
        case .driving: return .driving
        case .walking, .running: return .walk
        default: return nil
        }
    }
}

/// Minimal in-flight trip state, persisted so a background relaunch can resume/close an open trip.
private struct PendingTrip: Codable {
    var category: TripMotionCategory
    var startedAt: Date
    var startPlace: VisitSnapshot?
}

/// Subscribes to `KronikuEventBus` and fuses raw location/motion/workout signals into derived
/// "trip" and "workout" `MemoryEvent`s via the repository. One instance per app process.
/// Main-actor bound because the injected repository wraps a SwiftData `ModelContext`, which is not thread-safe.
@MainActor
final class TripCorrelator {
    private let repository: MemoryRepositoryProtocol
    private let defaults: UserDefaults
    private static let pendingTripKey = "tripCorrelatorPendingTrip"

    private var lastWaypoint: VisitSnapshot?
    private var lastMotionState: MotionState?
    private var subscriptionTask: Task<Void, Never>?

    init(repository: MemoryRepositoryProtocol, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
    }

    /// Begins consuming the shared event bus; safe to call multiple times (a prior subscription is torn down first).
    func start() {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            let stream = await KronikuEventBus.shared.subscribe()
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    /// Applies one signal to the correlation state machine; internal (not private) so tests can drive it
    /// deterministically without going through the async event bus.
    func handle(_ event: KronikuEvent) {
        switch event.type {
        case .locationSignificantChange:
            lastWaypoint = waypoint(from: event.metadata)
        case .motionChanged:
            handleMotionChanged(event)
        case .workoutStarted:
            break // Boundary is only actionable once `.workoutEnded` supplies the full duration.
        case .workoutEnded:
            handleWorkoutEnded(event)
        }
    }

    private func handleMotionChanged(_ event: KronikuEvent) {
        guard let rawState = event.metadata["state"], let state = MotionState(rawValue: rawState) else { return }
        let oldCategory = TripMotionCategory.category(for: lastMotionState)
        let newCategory = TripMotionCategory.category(for: state)
        lastMotionState = state

        guard newCategory != oldCategory else { return }

        if let oldCategory {
            endTrip(category: oldCategory, at: event.timestamp)
        }
        if let newCategory {
            beginTrip(category: newCategory, at: event.timestamp)
        }
    }

    private func beginTrip(category: TripMotionCategory, at date: Date) {
        guard loadPendingTrip() == nil else { return }
        let pending = PendingTrip(category: category, startedAt: date, startPlace: lastWaypoint)
        persistPendingTrip(pending)
    }

    private func endTrip(category: TripMotionCategory, at date: Date) {
        guard let pending = loadPendingTrip(), pending.category == category else { return }
        clearPendingTrip()

        let endPlace = lastWaypoint
        let detail: String?
        switch (pending.startPlace?.name, endPlace?.name) {
        case let (start?, end?) where start != end:
            detail = "\(start) → \(end)"
        case let (start?, _):
            detail = start
        case let (_, end?):
            detail = end
        default:
            detail = nil
        }

        do {
            try repository.addDerivedEvent(
                source: "trip",
                title: category.title,
                detail: detail,
                occurredAt: pending.startedAt,
                endedAt: date,
                motion: category.motionState,
                place: pending.startPlace ?? endPlace,
                confidenceScore: nil
            )
        } catch {
            print("Trip correlator failed to record derived trip: \(error)")
        }
    }

    private func handleWorkoutEnded(_ event: KronikuEvent) {
        guard
            let startedAtRaw = event.metadata["startedAt"],
            let startedAt = ISO8601DateFormatter().date(from: startedAtRaw)
        else { return }

        // Already a display-ready name (e.g. "Outdoor Run", "High Intensity Interval Training") from
        // HealthKitWorkoutObserver — don't re-title-case it, which would mangle acronym-like names.
        let activityTitle = event.metadata["activityType"] ?? "Workout"

        do {
            try repository.addDerivedEvent(
                source: "workout",
                title: activityTitle,
                detail: event.metadata["durationMinutes"].map { "\($0) min" },
                occurredAt: startedAt,
                endedAt: event.timestamp,
                motion: nil,
                place: nil,
                confidenceScore: nil
            )
        } catch {
            print("Trip correlator failed to record derived workout: \(error)")
        }
    }

    private func waypoint(from metadata: [String: String]) -> VisitSnapshot? {
        guard
            let name = metadata["placeName"],
            let latitude = metadata["latitude"].flatMap(Double.init),
            let longitude = metadata["longitude"].flatMap(Double.init)
        else { return nil }
        return VisitSnapshot(name: name, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude), capturedAt: Date())
    }

    private func loadPendingTrip() -> PendingTrip? {
        guard let data = defaults.data(forKey: Self.pendingTripKey) else { return nil }
        return try? JSONDecoder.iso8601.decode(PendingTrip.self, from: data)
    }

    private func persistPendingTrip(_ pending: PendingTrip) {
        guard let data = try? JSONEncoder.iso8601.encode(pending) else { return }
        defaults.set(data, forKey: Self.pendingTripKey)
    }

    private func clearPendingTrip() {
        defaults.removeObject(forKey: Self.pendingTripKey)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
