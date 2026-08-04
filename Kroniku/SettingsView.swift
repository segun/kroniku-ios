import SwiftUI

struct SettingsView: View {
    @Binding var showsTier1Onboarding: Bool

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController

    var body: some View {
        NavigationStack {
            ZStack {
                KronikuPalette.canvasGradient
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            KronikuLogoRow(subtitle: "Settings & Privacy")
                            Text("")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(KronikuPalette.paper)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                        if !contextController.consent.hasCompletedOnboarding || contextController.consent.needsOnboardingResume {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Tier 1 setup")
                                    .font(.headline.weight(.semibold))
                                    .fontDesign(.rounded)
                                Text("Resume onboarding at any time if you dismissed it before finishing.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Resume onboarding") {
                                    showsTier1Onboarding = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .kronikuCard(.context)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kroniku stores data locally on your device. Turning a source off removes its retained data from existing memories.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Toggle("Import calendar events", isOn: consentBinding(
                                get: { contextController.consent.calendarImportEnabled },
                                set: { contextController.setCalendarImportEnabled($0) },
                                syncCalendar: true
                            ))

                            Toggle("Include attendees and locations", isOn: consentBinding(
                                get: { contextController.consent.calendarAttendeesAndLocationsEnabled },
                                set: { contextController.setCalendarAttendeeLocationEnabled($0) },
                                syncCalendar: true
                            ))
                            .disabled(!contextController.consent.calendarImportEnabled)

                            Toggle("Attach nearby places", isOn: consentBinding(
                                get: { contextController.consent.locationCaptureEnabled },
                                set: { contextController.setLocationCaptureEnabled($0) }
                            ))

                            Toggle("Attach weather snapshots", isOn: consentBinding(
                                get: { contextController.consent.weatherSnapshotsEnabled },
                                set: { contextController.setWeatherSnapshotsEnabled($0) }
                            ))

                            Toggle("Attach motion state", isOn: consentBinding(
                                get: { contextController.consent.motionAttachmentEnabled },
                                set: { contextController.setMotionAttachmentEnabled($0) }
                            ))

                            Toggle("Allow photo attachments", isOn: consentBinding(
                                get: { contextController.consent.photoAttachmentEnabled },
                                set: { contextController.setPhotoAttachmentEnabled($0) }
                            ))

                            Toggle("When labels: sunrise, sunset, weekend, holiday", isOn: consentBinding(
                                get: { contextController.consent.timeSemanticsEnabled },
                                set: { contextController.setTimeSemanticsEnabled($0) }
                            ))
                        }
                        .kronikuCard(.calendar)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Health")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)
                            Text("Choose exactly which HealthKit metrics can be summarized onto eligible memories.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ForEach(Tier1HealthMetric.allCases) { metric in
                                Toggle(metric.title, isOn: healthMetricBinding(metric))
                            }

                            permissionRow(
                                title: "HealthKit",
                                status: contextController.healthPermission,
                                action: { Task { await contextController.requestHealthPermission() } }
                            )
                        }
                        .kronikuCard(.semantics)

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
                            permissionRow(
                                title: "HealthKit",
                                status: contextController.healthPermission,
                                action: { Task { await contextController.requestHealthPermission() } }
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

    private func consentBinding(get: @escaping () -> Bool, set: @escaping (Bool) -> Void, syncCalendar: Bool = false) -> Binding<Bool> {
        Binding(
            get: get,
            set: { newValue in
                updateConsent(syncCalendar: syncCalendar) {
                    set(newValue)
                }
            }
        )
    }

    private func healthMetricBinding(_ metric: Tier1HealthMetric) -> Binding<Bool> {
        Binding(
            get: { contextController.consent.healthConsent.enabledMetrics.contains(metric) },
            set: { enabled in
                updateConsent {
                    contextController.setHealthMetric(metric, enabled: enabled)
                }
            }
        )
    }

    private func updateConsent(syncCalendar: Bool = false, _ mutate: () -> Void) {
        mutate()
        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        Task {
            await contextController.applyRetention(into: repo)
            if syncCalendar {
                await contextController.syncCalendarEvents(into: repo)
            }
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
