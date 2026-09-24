import Foundation

/// Persists the user's named places (Home, Office, Gym, etc.) used for geofence monitoring.
@MainActor
final class GeofenceStore: ObservableObject {
    static let shared = GeofenceStore()

    /// iOS caps CLLocationManager region monitoring at 20 regions per app.
    static let maxMonitoredRegions = 20
    static let presetNames = ["Home", "Office", "Gym", "School"]

    @Published private(set) var places: [NamedGeofence] = []

    private let defaults: UserDefaults
    private let key = "namedGeofencesV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.places = Self.load(defaults: defaults, key: key)
    }

    func add(_ place: NamedGeofence) {
        places.append(place)
        persist()
    }

    func remove(_ id: UUID) {
        places.removeAll { $0.id == id }
        persist()
    }

    func place(forRegionId regionId: String) -> NamedGeofence? {
        places.first { $0.id.uuidString == regionId }
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
