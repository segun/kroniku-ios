import SwiftUI
import SwiftData

/// The single SwiftData container for the app; shared with `KronikuAppDelegate` so background
/// event handling never opens a second, independent container against the same store.
enum KronikuModelContainer {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: MemoryEvent.self, ContactMoment.self, Place.self, WeatherSnapshot.self)
        } catch {
            fatalError("Failed to create Kroniku's ModelContainer: \(error)")
        }
    }()
}

@main
struct KronikuApp: App {
    @UIApplicationDelegateAdaptor(KronikuAppDelegate.self) private var appDelegate
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
        .modelContainer(KronikuModelContainer.shared)
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

