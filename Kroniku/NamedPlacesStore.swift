import Foundation
import UserNotifications

extension Notification.Name {
    static let namePlaceRequested = Notification.Name("namePlaceRequested")
}

/// A location we've already prompted the user about, so we don't nag them again for the same spot.
private struct PendingPlacePrompt: Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let promptedAt: Date
}

/// Caches the user's named places, matches a coordinate against them, and prompts to name new ones.
@MainActor
final class NamedPlacesStore: ObservableObject {
    static let shared = NamedPlacesStore()

    /// Places within this radius are treated as the same spot, so GPS drift doesn't trigger a re-prompt.
    static let matchRadiusMeters: Double = 60

    @Published private(set) var places: [NamedPlaceResponse] = []

    private let service: NamedPlacesService
    private let defaults: UserDefaults
    private let cacheKey = "namedPlacesCache"
    private let pendingPromptsKey = "namedPlacesPendingPrompts"

    init(service: NamedPlacesService = .shared, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.places = Self.loadCache(defaults: defaults, key: cacheKey)
    }

    /// Refreshes the local cache from the backend; safe to call repeatedly (e.g. on app launch).
    func refresh() async {
        do {
            let fetched = try await service.list()
            places = fetched
            Self.saveCache(fetched, defaults: defaults, key: cacheKey)
        } catch {
            print("Named places refresh failed: \(error)")
        }
    }

    /// Returns the closest previously-named place within `matchRadiusMeters`, if any.
    func matchingPlace(latitude: Double, longitude: Double) -> NamedPlaceResponse? {
        places
            .map { ($0, Self.distanceMeters(lat1: latitude, lon1: longitude, lat2: $0.latitude, lon2: $0.longitude)) }
            .filter { $0.1 <= Self.matchRadiusMeters }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Saves a user-provided name for a place, clears any pending prompt for it, and refreshes the cache.
    func name(latitude: Double, longitude: Double, as name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await service.create(name: trimmed, latitude: latitude, longitude: longitude)
        clearPendingPrompt(latitude: latitude, longitude: longitude)
        await refresh()
    }

    /// Requests notification permission (if needed) and schedules a one-time "name this place" prompt,
    /// unless this location is already named or was already prompted for recently.
    func promptToNameIfNeeded(latitude: Double, longitude: Double) {
        guard matchingPlace(latitude: latitude, longitude: longitude) == nil else { return }
        guard matchingPendingPrompt(latitude: latitude, longitude: longitude) == nil else { return }

        let prompt = PendingPlacePrompt(id: UUID(), latitude: latitude, longitude: longitude, promptedAt: Date())
        recordPendingPrompt(prompt)

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }

            let content = UNMutableNotificationContent()
            content.title = "New place found"
            content.body = "We found a location we don't know about. Can you help name this place?"
            content.sound = .default
            content.userInfo = [
                "kind": "namePlace",
                "latitude": latitude,
                "longitude": longitude
            ]

            let request = UNNotificationRequest(
                identifier: prompt.id.uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func matchingPendingPrompt(latitude: Double, longitude: Double) -> PendingPlacePrompt? {
        loadPendingPrompts().first {
            Self.distanceMeters(lat1: latitude, lon1: longitude, lat2: $0.latitude, lon2: $0.longitude) <= Self.matchRadiusMeters
        }
    }

    private func recordPendingPrompt(_ prompt: PendingPlacePrompt) {
        var prompts = loadPendingPrompts()
        prompts.append(prompt)
        savePendingPrompts(prompts)
    }

    private func clearPendingPrompt(latitude: Double, longitude: Double) {
        var prompts = loadPendingPrompts()
        prompts.removeAll { Self.distanceMeters(lat1: latitude, lon1: longitude, lat2: $0.latitude, lon2: $0.longitude) <= Self.matchRadiusMeters }
        savePendingPrompts(prompts)
    }

    private func loadPendingPrompts() -> [PendingPlacePrompt] {
        guard let data = defaults.data(forKey: pendingPromptsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingPlacePrompt].self, from: data)) ?? []
    }

    private func savePendingPrompts(_ prompts: [PendingPlacePrompt]) {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: pendingPromptsKey)
    }

    private static func loadCache(defaults: UserDefaults, key: String) -> [NamedPlaceResponse] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NamedPlaceResponse].self, from: data)) ?? []
    }

    private static func saveCache(_ places: [NamedPlaceResponse], defaults: UserDefaults, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(places) else { return }
        defaults.set(data, forKey: key)
    }

    private static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
