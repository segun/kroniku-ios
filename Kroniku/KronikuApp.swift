import SwiftUI
import SwiftData

@main
struct KronikuApp: App {
    @State private var isAuthenticated = false
    private let authService = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if isAuthenticated {
                    RootTabView(isAuthenticated: $isAuthenticated)
                } else {
                    AuthView(isAuthenticated: $isAuthenticated)
                }
            }
            .onAppear {
                checkAuthStatus()
            }
        }
        .modelContainer(for: [MemoryEvent.self, ContactMoment.self, Place.self, WeatherSnapshot.self])
    }

    private func checkAuthStatus() {
        // Check if user has a valid access token
        if let _ = try? authService.getAccessToken() {
            isAuthenticated = true
        } else {
            isAuthenticated = false
        }
    }
}

