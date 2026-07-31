import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Privacy")) {
                    Text("Kroniku stores data locally on your device. We never request access to call logs or SMS. Microphone, calendar, and location access are requested only when you enable features that need them.")
                        .font(.subheadline)
                }

                Section(header: Text("Permissions")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Microphone", systemImage: "mic.fill")
                        Text("Used to record voice contact moments after you tap Record. Recordings are only stored after you review and confirm.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Calendar", systemImage: "calendar")
                        Text("Optional: import calendar events to show meetings alongside place and weather context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Location", systemImage: "location.fill")
                        Text("Optional: attach places and weather snapshots to meaningful events. Location is never tracked in the background without your explicit consent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Data")) {
                    Button("Export data…") { /* placeholder */ }
                    Button("Delete all local data") { /* placeholder */ }
                        .foregroundColor(.red)
                }

                Section(header: Text("About")) {
                    Text("Kroniku — Local memory for your day.")
                        .font(.subheadline)
                    Text("Version: 0.1 (local build)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings & privacy")
        }
    }
}
