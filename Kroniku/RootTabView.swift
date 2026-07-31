import SwiftUI

struct RootTabView: View {
    @State private var selectedTab: Tab = .timeline
    @State private var showsCapture = false

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
        .tint(.indigo)
        .sheet(isPresented: $showsCapture) {
            ContactMomentCaptureView()
        }
    }
}

private enum Tab: Hashable {
    case timeline, places, memory, settings
}
