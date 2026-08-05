import SwiftUI

struct RootTabView: View {
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

            SettingsView(showsTier1Onboarding: $showsTier1Onboarding)
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
        }
        .onAppear {
            if !contextController.consent.hasCompletedOnboarding && !contextController.consent.needsOnboardingResume {
                showsTier1Onboarding = true
            }
        }
        .preferredColorScheme(.light)
    }

    private func handleOnboardingDismissed() {
        guard !contextController.consent.hasCompletedOnboarding else { return }
        contextController.markOnboardingDismissed(at: contextController.consent.onboardingPage)
    }
}

private enum Tab: Hashable {
    case timeline, places, memory, settings
}
