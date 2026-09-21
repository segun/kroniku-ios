import SwiftUI
import UIKit

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case preferences = "Preferences"
    case contextSources = "Memory Details"
    case health = "Health"
    case permissions = "Permissions"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general: return "person.crop.circle"
        case .preferences: return "slider.horizontal.3"
        case .contextSources: return "sparkles"
        case .health: return "heart"
        case .permissions: return "hand.raised"
        }
    }
}

struct SettingsView: View {
    @Binding var showsTier1Onboarding: Bool
    @Binding var isAuthenticated: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var contextController: Tier1ContextController
    @EnvironmentObject private var tier2Controller: Tier2ContextController

    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationStack {
            ZStack {
                KronikuPalette.canvasGradient
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    sectionPicker

                    ScrollView {
                        VStack(spacing: 14) {
                            switch selectedSection {
                            case .general:
                                generalSection
                            case .preferences:
                                preferencesSection
                            case .contextSources:
                                contextSourcesSection
                            case .health:
                                healthSection
                            case .permissions:
                                permissionsSection
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                contextController.refreshPermissions()
                tier2Controller.refreshPermissions()
            }
        }
    }

    private var sectionPicker: some View {
        VStack(spacing: 8) {
            ForEach(SettingsSection.allCases) { section in
                let isSelected = section == selectedSection
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.iconName)
                            .font(.body.weight(.semibold))
                            .frame(width: 24)
                        Text(section.rawValue)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? KronikuPalette.ember : Color.black.opacity(0.045))
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var generalSection: some View {
        if !contextController.consent.hasCompletedOnboarding || contextController.consent.needsOnboardingResume {
            VStack(alignment: .leading, spacing: 10) {
                Text("Onboarding is not complete")
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

        VStack(alignment: .leading, spacing: 10) {
            Text("Your data")
                .font(.headline.weight(.semibold))
                .fontDesign(.rounded)
            Text("Your memories stay on this device. Export or remove them whenever you need.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Export Data") { }
                    .buttonStyle(.borderedProminent)
                    .tint(KronikuPalette.ember)
                Button("Delete all data") { }
                    .foregroundStyle(.red)
            }
        }
        .kronikuCard(.semantics)

        VStack(alignment: .leading, spacing: 10) {
            Text("Data")
                .font(.headline.weight(.semibold))
                .fontDesign(.rounded)
            Button(role: .destructive) {
                do {
                    try AuthService.shared.logout()
                    isAuthenticated = false
                } catch {
                    print("Sign out failed: \(error)")
                }
            }
            label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityHint("Signs out of your Kroniku account")

            Divider()

            Text("Kroniku — Local memory for your day.")
                .font(.subheadline)
            Text("Version 0.1")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .kronikuCard(.semantics)
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Day periods")
                .font(.headline.weight(.semibold))
                .fontDesign(.rounded)
            Text("Choose when each color period begins. Times must stay in order.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(DayPeriod.allCases, id: \.self) { period in
                DatePicker(
                    "\(period.title) starts",
                    selection: dayPeriodBinding(for: period),
                    displayedComponents: .hourAndMinute
                )
            }
        }
        .kronikuCard(.calendar)
    }

    private var contextSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
                            Text("Kroniku stores data locally on your device. Turning a detail off removes its retained data from existing memories.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Toggle("Add events from Calendar", isOn: consentBinding(
                                get: { contextController.consent.calendarImportEnabled },
                                set: { contextController.setCalendarImportEnabled($0) },
                                syncCalendar: true
                            ))

                            Toggle("Add people and places from Calendar", isOn: consentBinding(
                                get: { contextController.consent.calendarAttendeesAndLocationsEnabled },
                                set: { contextController.setCalendarAttendeeLocationEnabled($0) },
                                syncCalendar: true
                            ))
                            .disabled(!contextController.consent.calendarImportEnabled)

                            Toggle("Add nearby places", isOn: consentBinding(
                                get: { contextController.consent.locationCaptureEnabled },
                                set: { contextController.setLocationCaptureEnabled($0) }
                            ))

                            Toggle("Add weather", isOn: consentBinding(
                                get: { contextController.consent.weatherSnapshotsEnabled },
                                set: { contextController.setWeatherSnapshotsEnabled($0) }
                            ))

                            Toggle("Add movement", isOn: consentBinding(
                                get: { contextController.consent.motionAttachmentEnabled },
                                set: { contextController.setMotionAttachmentEnabled($0) }
                            ))

                            Toggle("Attach photos", isOn: consentBinding(
                                get: { contextController.consent.photoAttachmentEnabled },
                                set: { contextController.setPhotoAttachmentEnabled($0) }
                            ))

                            Toggle("Add time labels", isOn: consentBinding(
                                get: { contextController.consent.timeSemanticsEnabled },
                                set: { contextController.setTimeSemanticsEnabled($0) }
                            ))

                            Text("Time labels include sunrise, sunset, weekends, and holidays.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Divider()

                            Toggle("Turn spoken notes into text", isOn: consentBinding(
                                get: { contextController.consent.voiceTranscriptionEnabled },
                                set: { contextController.setVoiceTranscriptionEnabled($0) }
                            ))
                            Text("Turn a spoken recollection into editable details before saving.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Toggle("Use notes shared to Kroniku", isOn: consentBinding(
                                get: { contextController.consent.noteIngestionEnabled },
                                set: { contextController.setNoteIngestionEnabled($0) }
                            ))

                            Toggle("Match names to Contacts", isOn: consentBinding(
                                get: { contextController.consent.contactsResolutionEnabled },
                                set: { contextController.setContactsResolutionEnabled($0) }
                            ))
                            Text("Look up a person only when you ask Kroniku to resolve the name.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Toggle("Use nearby devices", isOn: consentBinding(
                                get: { contextController.consent.bluetoothContextEnabled },
                                set: { contextController.setBluetoothContextEnabled($0) }
                            ))
                            Text("Nearby devices can add details like car or headphones.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .kronikuCard(.calendar)
    }

    private var healthSection: some View {
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

                        }
                        .kronikuCard(.semantics)
    }

    @ViewBuilder
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
                            Text("Voice, contacts, and bluetooth permissions")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)

                            permissionRow(
                                title: "Microphone",
                                status: tier2Controller.microphonePermission,
                                isBusy: tier2Controller.isRequestingMicrophonePermission,
                                action: { Task { await tier2Controller.requestMicrophonePermission() } }
                            )

                            permissionRow(
                                title: "Speech recognition",
                                status: tier2Controller.speechPermission,
                                isBusy: tier2Controller.isRequestingSpeechPermission,
                                action: { Task { await tier2Controller.requestSpeechPermission() } }
                            )

                            permissionRow(
                                title: "Contacts",
                                status: tier2Controller.contactsPermission,
                                action: { Task { await tier2Controller.requestContactsPermission() } }
                            )

                            permissionRow(
                                title: "Bluetooth",
                                status: tier2Controller.bluetoothPermission,
                                action: { Task { await tier2Controller.requestBluetoothPermission() } }
                            )
                        }
                        .kronikuCard(.context)

        VStack(alignment: .leading, spacing: 10) {
                            Text("Calendar, location, motion, and Health permissions")
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
    }

    private func consentBinding(get: @escaping @Sendable () -> Bool, set: @escaping @Sendable (Bool) -> Void, syncCalendar: Bool = false) -> Binding<Bool> {
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

    private func dayPeriodBinding(for period: DayPeriod) -> Binding<Date> {
        Binding(
            get: {
                periodDate(minutes: contextController.consent.effectiveDayPeriodSchedule.startMinutes(for: period))
            },
            set: { date in
                let calendar = Calendar.current
                let components = calendar.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var schedule = contextController.consent.effectiveDayPeriodSchedule
                switch period {
                case .morning:
                    schedule.morningStartMinutes = minutes
                case .afternoon:
                    schedule.afternoonStartMinutes = minutes
                case .earlyEvening:
                    schedule.earlyEveningStartMinutes = minutes
                case .night:
                    schedule.nightStartMinutes = minutes
                }
                contextController.setDayPeriodSchedule(schedule)
            }
        )
    }

    private func periodDate(minutes: Int) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minutes, to: startOfDay) ?? startOfDay
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

    private func permissionRow(title: String, status: PermissionState, isBusy: Bool = false, canRetryWhenDenied: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status == .notDetermined {
                Button(isBusy ? "Requesting..." : "Allow", action: action)
                    .disabled(isBusy)
            } else if status == .denied || status == .restricted {
                if canRetryWhenDenied {
                    Button("Review access", action: action)
                        .font(.caption.weight(.semibold))
                } else {
                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .font(.caption.weight(.semibold))
                }
            } else {
                Text("Allowed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
