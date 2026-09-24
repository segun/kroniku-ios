import SwiftUI
import SwiftData

extension Notification.Name {
    static let contextRequestOpened = Notification.Name("contextRequestOpened")
    static let openPlacesSettingsRequested = Notification.Name("openPlacesSettingsRequested")
}

struct RootTabView: View {
    @Binding var isAuthenticated: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: Tab = .timeline
    @State private var showsCapture = false
    @State private var showsTier1Onboarding = false
    @State private var captureLinkedEventIDs: Set<UUID> = []
    @StateObject private var contextController = Tier1ContextController()
    @StateObject private var tier2Controller = Tier2ContextController()
    @StateObject private var contextRequestStore = ContextRequestStore.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView(showsCapture: $showsCapture)
                .tabItem { Label("Timeline", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
                .tag(Tab.timeline)

            MemoryView()
                .tabItem { Label("Memory", systemImage: "sparkles") }
                .tag(Tab.memory)

            ContextRequestsView(store: contextRequestStore)
                .tabItem { Label("Inbox", systemImage: "bell") }
                .badge(contextRequestStore.unreadCount)
                .tag(Tab.inbox)

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
        .onAppear {
            guard AuthService.shared.isAuthenticated else { return }
            if !contextController.consent.hasCompletedOnboarding && !contextController.consent.needsOnboardingResume {
                showsTier1Onboarding = true
            }
            contextController.resumeBackgroundMonitoringIfNeeded()
            contextController.refreshGeofenceMonitoringIfNeeded()
            contextController.resumeSleepTrackingIfNeeded()
            openPendingContextRequestIfNeeded()
            Task {
                await contextController.pushDayPeriodsIfNeeded()
                await contextController.pullDayPeriodsIfNeeded()
                if contextController.consent.backgroundTripDetectionEnabled {
                    await contextRequestStore.requestPermissionAndSchedulePending()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryRepositoryChanged)) { _ in
            runPushPending()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authSessionExpired)) { _ in
            handleExpiredSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextRequestOpened)) { note in
            guard let requestID = note.userInfo?["requestID"] as? UUID else { return }
            UserDefaults.standard.removeObject(forKey: "pendingContextRequestID")
            contextRequestStore.queueOpen(requestID)
            selectedTab = .inbox
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlacesSettingsRequested)) { _ in
            selectedTab = .settings
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

    private func openPendingContextRequestIfNeeded() {
        guard let rawID = UserDefaults.standard.string(forKey: "pendingContextRequestID"),
              let requestID = UUID(uuidString: rawID) else { return }
        UserDefaults.standard.removeObject(forKey: "pendingContextRequestID")
          contextRequestStore.queueOpen(requestID)
        selectedTab = .inbox
    }

    private func handleExpiredSession() {
        try? AuthService.shared.logout()
        isAuthenticated = false
    }
}

private enum Tab: Hashable {
    case timeline, memory, inbox, settings
}
