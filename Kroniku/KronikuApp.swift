import SwiftUI
import SwiftData

@main
struct KronikuApp: App {
    @State private var isAuthenticated = false
    @State private var hasCompletedWelcome = UserDefaults.standard.bool(forKey: Self.hasCompletedWelcomeKey)
    private let authService = AuthService.shared

    private static let hasCompletedWelcomeKey = "hasCompletedWelcomeOnboarding"

    var body: some Scene {
        WindowGroup {
            Group {
                if !hasCompletedWelcome {
                    WelcomeOnboardingView {
                        UserDefaults.standard.set(true, forKey: Self.hasCompletedWelcomeKey)
                        withAnimation { hasCompletedWelcome = true }
                    }
                } else if isAuthenticated {
                    AuthenticatedRootView(isAuthenticated: $isAuthenticated)
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
        if authService.isAuthenticated {
            isAuthenticated = true
        } else {
            isAuthenticated = false
        }
    }
}

private struct AuthenticatedRootView: View {
    @Binding var isAuthenticated: Bool
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        RootTabView(isAuthenticated: $isAuthenticated)
            .task {
                let coordinator = SyncCoordinator(
                    repository: SwiftDataMemoryRepository(modelContext: modelContext)
                )
                try? await coordinator.performFullSync()
            }
    }
}

