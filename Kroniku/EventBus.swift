import Foundation
import OSLog

enum SensorDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Kroniku",
        category: "SensorDiagnostics"
    )

    static func log(_ message: String) {
#if DEBUG
        logger.notice("[SensorDiagnostics] \(message, privacy: .public)")
#endif
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Normalized signal type published by background-capable providers (location, motion, HealthKit).
enum KronikuEventType: String, Codable {
    case locationSignificantChange
    case motionChanged
    case workoutStarted
    case workoutEnded
}

/// A single normalized signal from any background source, consumed by `TripCorrelator`.
struct KronikuEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let type: KronikuEventType
    let source: String
    let metadata: [String: String]

    init(id: UUID = UUID(), timestamp: Date = Date(), type: KronikuEventType, source: String, metadata: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.source = source
        self.metadata = metadata
    }
}

/// Fan-out publish/subscribe hub decoupling background signal providers from the correlator that consumes them.
actor KronikuEventBus {
    static let shared = KronikuEventBus()

    private var continuations: [UUID: AsyncStream<KronikuEvent>.Continuation] = [:]

    func publish(_ event: KronikuEvent) {
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        SensorDiagnostics.log(
            "BUS publish type=\(event.type.rawValue) source=\(event.source) " +
            "timestamp=\(SensorDiagnostics.timestamp(event.timestamp)) metadata={\(metadata)} " +
            "subscribers=\(continuations.count)"
        )
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Each call returns an independent stream; callers should iterate it in a long-lived `Task`.
    func subscribe() -> AsyncStream<KronikuEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
