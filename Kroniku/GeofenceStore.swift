import Foundation

/// Persists the user's named places (Home, Office, Gym, etc.) used for geofence monitoring.
@MainActor
final class GeofenceStore: ObservableObject {
    static let shared = GeofenceStore()

    /// iOS caps CLLocationManager region monitoring at 20 regions per app.
    static let maxMonitoredRegions = 20
    static let presetNames = ["Home", "Office", "Gym", "School"]

    @Published private(set) var places: [NamedGeofence] = []

    private let service: GeofenceService
    private let defaults: UserDefaults
    private let key = "namedGeofencesV1"

    init(service: GeofenceService = .shared, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.places = Self.load(defaults: defaults, key: key)
    }

    func add(_ place: NamedGeofence) {
        places.append(place)
        persist()
        Task {
            do {
                _ = try await service.upsert(place)
            } catch {
                print("Geofence sync (create) failed: \(error)")
            }
        }
    }

    func remove(_ id: UUID) {
        places.removeAll { $0.id == id }
        persist()
        Task {
            do {
                try await service.delete(id: id)
            } catch {
                print("Geofence sync (delete) failed: \(error)")
            }
        }
    }

    func place(forRegionId regionId: String) -> NamedGeofence? {
        places.first { $0.id.uuidString == regionId }
    }

    /// Replaces the local cache with the backend's list; safe to call repeatedly (e.g. on app launch).
    func refresh() async {
        do {
            let fetched = try await service.list()
            places = fetched
            persist()
        } catch {
            print("Geofences refresh failed: \(error)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [NamedGeofence] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([NamedGeofence].self, from: data)) ?? []
    }
}
