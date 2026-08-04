import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var contextController: Tier1ContextController

    var body: some View {
        NavigationStack {
            ZStack {
                KronikuPalette.canvasGradient
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            KronikuLogoRow(subtitle: "Privacy Control")
                            Text("Settings & privacy")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(KronikuPalette.paper)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kroniku stores data locally on your device. Permissions are requested only when you explicitly enable related features.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Toggle("Import calendar events", isOn: Binding(
                                get: { contextController.consent.calendarImportEnabled },
                                set: { contextController.setCalendarImportEnabled($0) }
                            ))

                            Toggle("Include attendees and locations", isOn: Binding(
                                get: { contextController.consent.calendarAttendeesAndLocationsEnabled },
                                set: { contextController.setCalendarAttendeeLocationEnabled($0) }
                            ))

                            Toggle("Attach location visits", isOn: Binding(
                                get: { contextController.consent.locationCaptureEnabled },
                                set: { contextController.setLocationCaptureEnabled($0) }
                            ))

                            Toggle("Attach weather snapshots", isOn: Binding(
                                get: { contextController.consent.weatherSnapshotsEnabled },
                                set: { contextController.setWeatherSnapshotsEnabled($0) }
                            ))

                            Toggle("Attach motion state", isOn: Binding(
                                get: { contextController.consent.motionAttachmentEnabled },
                                set: { contextController.setMotionAttachmentEnabled($0) }
                            ))

                            Toggle("Add sunrise/sunset/weekend/holiday labels", isOn: Binding(
                                get: { contextController.consent.timeSemanticsEnabled },
                                set: { contextController.setTimeSemanticsEnabled($0) }
                            ))
                        }
                        .kronikuCard(.calendar)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Permissions")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)

                            permissionRow(
                                title: "Calendar",
                                status: contextController.calendarPermission,
                                action: { Task { await contextController.requestCalendarPermission() } }
                            )
                            permissionRow(
                                title: "Location",
                                status: contextController.locationPermission,
                                action: { Task { await contextController.requestLocationPermission() } }
                            )
                            permissionRow(
                                title: "Motion",
                                status: contextController.motionPermission,
                                action: { Task { await contextController.requestMotionPermission() } }
                            )
                        }
                        .kronikuCard(.context)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Data")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)
                            Button("Export data…") { }
                            Button("Delete all local data") { }
                                .foregroundStyle(.red)

                            Divider()

                            Text("Kroniku — Local memory for your day.")
                                .font(.subheadline)
                            Text("Version 0.1")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .kronikuCard(.semantics)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("Settings")
            .onAppear { contextController.refreshPermissions() }
        }
    }

    private func permissionRow(title: String, status: PermissionState, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status == .notDetermined {
                Button("Allow", action: action)
            } else {
                Text(status == .authorized ? "Allowed" : "Denied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
