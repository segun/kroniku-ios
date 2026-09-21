import SwiftUI
import UIKit

struct Tier1OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var contextController: Tier1ContextController
    @EnvironmentObject private var tier2Controller: Tier2ContextController

    @State private var currentPage = 0

    private let lastPage = 2

    var body: some View {
        NavigationStack {
            ZStack {
                KronikuPalette.canvasGradient
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        KronikuLogoRow(subtitle: "Onboarding")
                        Text("Memory details")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(KronikuPalette.paper)
                        Text("Choose what Kroniku can use when it adds helpful details to your memories.")
                            .font(.subheadline)
                            .foregroundStyle(KronikuPalette.fog)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Group {
                        switch currentPage {
                        case 0:
                            onboardingPageOne
                        case 1:
                            onboardingPageTwo
                        default:
                            onboardingPageThree
                        }
                    }
                    .animation(.easeInOut, value: currentPage)

                    pageControls
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("Memory details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        contextController.markOnboardingDismissed(at: currentPage)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(currentPage == lastPage ? "Done" : "Next") {
                        advance()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            contextController.refreshPermissions()
            tier2Controller.refreshPermissions()
            currentPage = min(contextController.consent.onboardingPage, lastPage)
        }
        .onChange(of: currentPage) { _, newValue in
            contextController.updateOnboardingPage(newValue)
        }
        .preferredColorScheme(.light)
    }

    private var onboardingPageOne: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Around you")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Text("Allow these when you want memories to include nearby places, weather, and movement.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

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
                    Text("Calendar")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

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

                    Text("Calendar locations come from your calendar event details and are separate from nearby-place capture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    permissionRow(
                        title: "Calendar access",
                        status: contextController.calendarPermission,
                        action: { Task { await contextController.requestCalendarPermission() } }
                    )
                }
                .kronikuCard(.calendar)
            }
        }
    }

    private var onboardingPageTwo: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Health")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Text("Allow this when you want eligible memories to include activity, sleep, or mindfulness summaries.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    permissionRow(
                        title: "Health",
                        status: contextController.healthPermission,
                        canRetryWhenDenied: true,
                        action: { Task { await contextController.requestHealthPermission() } }
                    )
                }
                .kronikuCard(.semantics)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Photos")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Toggle("Attach photos", isOn: consentBinding(
                        get: { contextController.consent.photoAttachmentEnabled },
                        set: { contextController.setPhotoAttachmentEnabled($0) }
                    ))

                    Text("When enabled, contact moments can keep selected photos alongside their notes. Turning it off removes saved photo links.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .kronikuCard(.context)
            }
        }
    }

    private var onboardingPageThree: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Words and time")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Toggle("Add time labels", isOn: consentBinding(
                        get: { contextController.consent.timeSemanticsEnabled },
                        set: { contextController.setTimeSemanticsEnabled($0) }
                    ))

                    Toggle("Turn spoken notes into text", isOn: consentBinding(
                        get: { contextController.consent.voiceTranscriptionEnabled },
                        set: { contextController.setVoiceTranscriptionEnabled($0) }
                    ))

                    Toggle("Use notes shared to Kroniku", isOn: consentBinding(
                        get: { contextController.consent.noteIngestionEnabled },
                        set: { contextController.setNoteIngestionEnabled($0) }
                    ))

                    Text("Time labels include sunrise, sunset, weekends, and holidays. Shared notes are only used when you send them to Kroniku.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .kronikuCard(.semantics)

                VStack(alignment: .leading, spacing: 10) {
                    Text("People and devices")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Toggle("Match names to Contacts", isOn: consentBinding(
                        get: { contextController.consent.contactsResolutionEnabled },
                        set: { contextController.setContactsResolutionEnabled($0) }
                    ))

                    Toggle("Use nearby devices", isOn: consentBinding(
                        get: { contextController.consent.bluetoothContextEnabled },
                        set: { contextController.setBluetoothContextEnabled($0) }
                    ))

                    Text("Contacts are checked only when you ask Kroniku to match a name. Nearby devices can add details like car or headphones.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .kronikuCard(.calendar)

                VStack(alignment: .leading, spacing: 10) {
                    Text("More permissions")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    permissionRow(
                        title: "Microphone",
                        status: tier2Controller.microphonePermission,
                        action: { Task { await tier2Controller.requestMicrophonePermission() } }
                    )

                    permissionRow(
                        title: "Speech recognition",
                        status: tier2Controller.speechPermission,
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
            }
        }
    }

    private var pageControls: some View {
        HStack {
            Button("Back") {
                currentPage = max(0, currentPage - 1)
            }
            .disabled(currentPage == 0)

            Spacer()

            Text("Page \(currentPage + 1) of \(lastPage + 1)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button(currentPage == lastPage ? "Finish" : "Next") {
                advance()
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 6)
    }

    private func advance() {
        guard currentPage < lastPage else {
            contextController.markOnboardingComplete()
            dismiss()
            return
        }
        currentPage += 1
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

    private func permissionRow(title: String, status: PermissionState, canRetryWhenDenied: Bool = false, action: @escaping () -> Void) -> some View {
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
                    .buttonStyle(.bordered)
            } else if status == .denied || status == .restricted {
                if canRetryWhenDenied {
                    Button("Review access", action: action)
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                } else {
                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                }
            } else {
                Text("Allowed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
