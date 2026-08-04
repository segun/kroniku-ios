import SwiftUI

struct RootTabView: View {
    @State private var selectedTab: Tab = .timeline
    @State private var showsCapture = false
    @State private var showsTier1Onboarding = false
    @StateObject private var contextController = Tier1ContextController()

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

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(KronikuPalette.ember)
        .toolbarBackground(KronikuPalette.paper, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environmentObject(contextController)
        .sheet(isPresented: $showsCapture) {
            ContactMomentCaptureView()
                .environmentObject(contextController)
        }
        .sheet(isPresented: $showsTier1Onboarding) {
            Tier1OnboardingView()
                .environmentObject(contextController)
        }
        .onAppear {
            if !contextController.consent.hasCompletedOnboarding {
                showsTier1Onboarding = true
            }
        }
        .preferredColorScheme(.light)
    }
}

private enum Tab: Hashable {
    case timeline, places, memory, settings
}
