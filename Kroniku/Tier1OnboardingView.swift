import SwiftUI

struct Tier1OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var contextController: Tier1ContextController

    @State private var includeCalendarPeopleAndPlaces = false
    @State private var includeLocationContext = false
    @State private var includeWeather = false
    @State private var includeMotion = false

    var body: some View {
        NavigationStack {
            ZStack {
                KronikuPalette.canvasGradient
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            KronikuLogoRow(subtitle: "Tier 1 Onboarding")
                            Text("Context preferences")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(KronikuPalette.paper)
                            Text("Pick exactly which context sources can enrich your memory timeline.")
                                .font(.subheadline)
                                .foregroundStyle(KronikuPalette.fog)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Calendar")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)

                            Toggle("Import calendar events", isOn: Binding(
                                get: { contextController.consent.calendarImportEnabled },
                                set: { contextController.setCalendarImportEnabled($0) }
                            ))

                            Toggle("Include attendees and locations", isOn: $includeCalendarPeopleAndPlaces)
                                .onChange(of: includeCalendarPeopleAndPlaces) { _, newValue in
                                    contextController.setCalendarAttendeeLocationEnabled(newValue)
                                }

                            permissionRow(
                                title: "Calendar permission",
                                status: contextController.calendarPermission,
                                action: { Task { await contextController.requestCalendarPermission() } }
                            )
                        }
                        .kronikuCard(.calendar)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Context capture")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)

                            Toggle("Attach location visits", isOn: $includeLocationContext)
                                .onChange(of: includeLocationContext) { _, newValue in
                                    contextController.setLocationCaptureEnabled(newValue)
                                }

                            Toggle("Attach weather snapshots", isOn: $includeWeather)
                                .onChange(of: includeWeather) { _, newValue in
                                    contextController.setWeatherSnapshotsEnabled(newValue)
                                }

                            Toggle("Attach motion state", isOn: $includeMotion)
                                .onChange(of: includeMotion) { _, newValue in
                                    contextController.setMotionAttachmentEnabled(newValue)
                                }

                            permissionRow(
                                title: "Location permission",
                                status: contextController.locationPermission,
                                action: { Task { await contextController.requestLocationPermission() } }
                            )

                            permissionRow(
                                title: "Motion permission",
                                status: contextController.motionPermission,
                                action: { Task { await contextController.requestMotionPermission() } }
                            )
                        }
                        .kronikuCard(.context)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Time semantics")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)

                            Toggle("Add sunrise/sunset + weekend + holiday labels", isOn: Binding(
                                get: { contextController.consent.timeSemanticsEnabled },
                                set: { contextController.setTimeSemanticsEnabled($0) }
                            ))

                            Text("You can revoke any permission in Settings at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .kronikuCard(.semantics)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("Context preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        contextController.markOnboardingComplete()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            contextController.refreshPermissions()
            includeCalendarPeopleAndPlaces = contextController.consent.calendarAttendeesAndLocationsEnabled
            includeLocationContext = contextController.consent.locationCaptureEnabled
            includeWeather = contextController.consent.weatherSnapshotsEnabled
            includeMotion = contextController.consent.motionAttachmentEnabled
        }
        .preferredColorScheme(.light)
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
            } else if status == .denied || status == .restricted {
                Text("Denied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Allowed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
