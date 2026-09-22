import SwiftUI
import SwiftData

extension Notification.Name {
    static let tripStopContextRequested = Notification.Name("tripStopContextRequested")
}

struct RootTabView: View {
    @Binding var isAuthenticated: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: Tab = .timeline
    @State private var showsCapture = false
    @State private var showsTier1Onboarding = false
    @State private var pendingPlaceCoordinate: GeoCoordinate?
    @State private var captureLinkedEventIDs: Set<UUID> = []
    @StateObject private var contextController = Tier1ContextController()
    @StateObject private var tier2Controller = Tier2ContextController()

    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView(showsCapture: $showsCapture)
                .tabItem { Label("Timeline", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
                .tag(Tab.timeline)

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
            ContactMomentCaptureView(prelinkedEventIDs: captureLinkedEventIDs)
                .environmentObject(contextController)
            .environmentObject(tier2Controller)
        }
        .sheet(isPresented: $showsTier1Onboarding, onDismiss: handleOnboardingDismissed) {
            Tier1OnboardingView()
                .environmentObject(contextController)
                .environmentObject(tier2Controller)
        }
        .sheet(item: $pendingPlaceCoordinate) { coordinate in
            NamePlaceView(coordinate: coordinate)
        }
        .onAppear {
            guard AuthService.shared.isAuthenticated else { return }
            if !contextController.consent.hasCompletedOnboarding && !contextController.consent.needsOnboardingResume {
                showsTier1Onboarding = true
            }
            contextController.resumeBackgroundMonitoringIfNeeded()
            Task {
                await contextController.pushDayPeriodsIfNeeded()
                await contextController.pullDayPeriodsIfNeeded()
                await NamedPlacesStore.shared.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryRepositoryChanged)) { _ in
            runPushPending()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authSessionExpired)) { _ in
            handleExpiredSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .namePlaceRequested)) { note in
            guard let latitude = note.userInfo?["latitude"] as? Double, let longitude = note.userInfo?["longitude"] as? Double else { return }
            pendingPlaceCoordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tripStopContextRequested)) { note in
            guard let eventID = note.userInfo?["eventID"] as? UUID else { return }
            captureLinkedEventIDs = [eventID]
            selectedTab = .timeline
            showsCapture = true
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
    case timeline, memory, settings
}
