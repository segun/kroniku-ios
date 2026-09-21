import SwiftUI
import SwiftData

struct RootTabView: View {
    @Binding var isAuthenticated: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: Tab = .timeline
    @State private var showsCapture = false
    @State private var showsTier1Onboarding = false
    @StateObject private var contextController = Tier1ContextController()
    @StateObject private var tier2Controller = Tier2ContextController()

    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView(showsCapture: $showsCapture)
                .tabItem { Label("Timeline", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
                .tag(Tab.timeline)

            PlacesView()
                .tabItem { Label("Places", systemImage: "map") }
                .tag(Tab.places)

            MemoryView()
                .tabItem { Label("Memory", systemImage: "sparkles") }
                .tag(Tab.memory)

            SettingsView(
                showsTier1Onboarding: $showsTier1Onboarding,
                isAuthenticated: $isAuthenticated
            )
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(KronikuPalette.ember)
        .toolbarBackground(KronikuPalette.paper, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environmentObject(contextController)
        .environmentObject(tier2Controller)
        .sheet(isPresented: $showsCapture) {
            ContactMomentCaptureView()
                .environmentObject(contextController)
            .environmentObject(tier2Controller)
        }
        .sheet(isPresented: $showsTier1Onboarding, onDismiss: handleOnboardingDismissed) {
            Tier1OnboardingView()
                .environmentObject(contextController)
                .environmentObject(tier2Controller)
        }
        .onAppear {
            guard AuthService.shared.isAuthenticated else { return }
            if !contextController.consent.hasCompletedOnboarding && !contextController.consent.needsOnboardingResume {
                showsTier1Onboarding = true
            }
            Task {
                await contextController.pushDayPeriodsIfNeeded()
                await contextController.pullDayPeriodsIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryRepositoryChanged)) { _ in
            runPushPending()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authSessionExpired)) { _ in
            handleExpiredSession()
        }
        .preferredColorScheme(.light)
    }

    private func handleOnboardingDismissed() {
        guard !contextController.consent.hasCompletedOnboarding else { return }
        contextController.markOnboardingDismissed(at: contextController.consent.onboardingPage)
    }

    private func runPushPending() {
        let coordinator = SyncCoordinator(repository: SwiftDataMemoryRepository(modelContext: modelContext))
        Task { try? await coordinator.pushPending() }
    }

    private func handleExpiredSession() {
        try? AuthService.shared.logout()
        isAuthenticated = false
    }
}

private enum Tab: Hashable {
    case timeline, places, memory, settings
}
