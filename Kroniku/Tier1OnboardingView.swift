import SwiftUI
import UIKit

struct Tier1OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var contextController: Tier1ContextController

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

                    TabView(selection: $currentPage) {
                        onboardingPageOne
                            .tag(0)
                        onboardingPageTwo
                            .tag(1)
                        onboardingPageThree
                            .tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))

                    pageControls
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("Context preferences")
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
                    Text("Context capture")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Text("Grant permission first. When you allow access, Kroniku enables nearby places, weather snapshots, and motion state by default.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

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
                    Text("Calendar")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

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

                    Text("Calendar locations come from your calendar event details and are separate from nearby-place capture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    permissionRow(
                        title: "Calendar permission",
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
                    Text("HealthKit")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Text("Grant permission first. Kroniku enables Steps, Heart rate, Sleep, and Mindful minutes by default after you allow access.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    permissionRow(
                        title: "HealthKit permission",
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

                    Toggle("Allow photo attachments", isOn: consentBinding(
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
                    Text("When")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    Toggle("When labels: sunrise, sunset, weekend, holiday", isOn: consentBinding(
                        get: { contextController.consent.timeSemanticsEnabled },
                        set: { contextController.setTimeSemanticsEnabled($0) }
                    ))

                    Text("Every source stays under per-source control in Settings. Turning one off removes retained data from existing memories for that source.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .kronikuCard(.semantics)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Resume anytime")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)
                    Text("If you dismiss onboarding by mistake, use Settings to resume exactly where you left off.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .kronikuCard(.calendar)
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
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
