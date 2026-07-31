import SwiftUI
import SwiftData

@main
struct KronikuApp: App {
    // Provide a model container so SwiftData-backed models are available app-wide.
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [MemoryEvent.self, ContactMoment.self, Place.self, WeatherSnapshot.self])
    }
}
