import Foundation
import SwiftUI
import SwiftData
import UserNotifications

enum ContextRequestAction: String, Codable {
    case memoryEvent
    case openPlacesSettings
}

struct ContextRequest: Codable, Identifiable, Hashable {
    var id: UUID
    var eventID: UUID
    var title: String
    var message: String
    var createdAt: Date
    var viewedAt: Date?
    var notifiedAt: Date?
    var dismissalKey: String? = nil
    // Optional so previously-persisted requests (which predate this field) still decode.
    var action: ContextRequestAction? = nil

    var resolvedAction: ContextRequestAction { action ?? .memoryEvent }
}

@MainActor
final class ContextRequestStore: ObservableObject {
    static let shared = ContextRequestStore()

    @Published private(set) var requests: [ContextRequest]
    @Published private(set) var pendingOpenRequestID: UUID?
    private let defaults: UserDefaults
    private let storageKey = "contextRequestsV1"
    private let dismissedEventsKey = "dismissedContextRequestEventsV1"
    private var dismissedEvents: [String: Date]
    private let dismissalRetention: TimeInterval = 30 * 24 * 60 * 60
    private let placesPromptShownKey = "placesSetupPromptShownV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.requests = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([ContextRequest].self, from: $0) } ?? []
        self.dismissedEvents = defaults.data(forKey: dismissedEventsKey)
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        pruneDismissedEvents()
        updateAppBadge()
    }

    var unreadCount: Int { requests.lazy.filter { $0.viewedAt == nil }.count }

    /// Re-applies the current unread count to the app icon; call when the app returns to the foreground
    /// in case the system badge drifted (e.g. cleared from the notification center).
    func syncAppBadge() {
        updateAppBadge()
    }

    func enqueueStop(eventID: UUID, placeName: String, durationMinutes: Int, createdAt: Date) {
        pruneDismissedEvents()
        let stableStopKey = stableStopDismissalKey(placeName: placeName, createdAt: createdAt)
        guard dismissedEvents[eventID.uuidString] == nil,
              dismissedEvents[stableStopKey] == nil,
              !requests.contains(where: { $0.eventID == eventID }) else { return }
        requests.append(ContextRequest(
            id: UUID(),
            eventID: eventID,
            title: "Add context to your stop",
            message: "You stopped at \(placeName) for \(durationMinutes) min. What happened there?",
            createdAt: createdAt,
            dismissalKey: stableStopKey
        ))
        persist()
        if UIApplication.shared.applicationState != .active {
            Task { await schedulePendingNotifications(requestPermission: false) }
        }
    }

    /// One-time nudge shown right after onboarding; the shown flag is set immediately so it never reappears,
    /// regardless of whether the user views or deletes it.
    func enqueuePlacesSetupPromptIfNeeded() {
        guard !defaults.bool(forKey: placesPromptShownKey) else { return }
        defaults.set(true, forKey: placesPromptShownKey)
        requests.append(ContextRequest(
            id: UUID(),
            eventID: UUID(),
            title: "Set up your places",
            message: "Add Home, Work, and other places so Kroniku recognizes your comings and goings — powering automatic stop detection, arrival/departure memories, and geofenced reminders.",
            createdAt: Date(),
            action: .openPlacesSettings
        ))
        persist()
        if UIApplication.shared.applicationState != .active {
            Task { await schedulePendingNotifications(requestPermission: false) }
        }
    }

    func markViewed(_ requestID: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == requestID }), requests[index].viewedAt == nil else { return }
        requests[index].viewedAt = Date()
        let notificationID = "context-request-\(requests[index].id.uuidString)"
        persist()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    func delete(_ requestID: UUID) {
        guard let request = requests.first(where: { $0.id == requestID }) else { return }
        requests.removeAll { $0.id == requestID }
        if pendingOpenRequestID == requestID {
            pendingOpenRequestID = nil
        }
        let dismissedAt = Date()
        dismissedEvents[request.eventID.uuidString] = dismissedAt
        if let dismissalKey = request.dismissalKey {
            dismissedEvents[dismissalKey] = dismissedAt
        }
        persistDismissedEvents()
        persist()
        let notificationID = "context-request-\(request.id.uuidString)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    func queueOpen(_ requestID: UUID) {
        pendingOpenRequestID = nil
        Task { @MainActor [weak self] in
            self?.pendingOpenRequestID = requestID
        }
    }

    func consumePendingOpenRequestID() -> UUID? {
        defer { pendingOpenRequestID = nil }
        return pendingOpenRequestID
    }

    func requestPermissionAndSchedulePending() async {
        await schedulePendingNotifications(requestPermission: true)
    }

    private func schedulePendingNotifications(requestPermission: Bool) async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if requestPermission && settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for index in requests.indices where requests[index].viewedAt == nil && requests[index].notifiedAt == nil {
            let content = UNMutableNotificationContent()
            content.title = requests[index].title
            content.body = requests[index].message
            content.sound = .default
            content.userInfo = [
                "kind": "contextRequest",
                "requestID": requests[index].id.uuidString
            ]
            let request = UNNotificationRequest(
                identifier: "context-request-\(requests[index].id.uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            do {
                try await center.add(request)
                requests[index].notifiedAt = Date()
            } catch {
                SensorDiagnostics.log("CONTEXT REQUEST notification failed error=\(error.localizedDescription)")
            }
        }
        persist()
    }

    private func persist() {
        requests.sort { $0.createdAt > $1.createdAt }
        if let data = try? JSONEncoder().encode(requests) {
            defaults.set(data, forKey: storageKey)
        }
        updateAppBadge()
    }

    /// Mirrors the inbox's unread count onto the app icon, WhatsApp-style; no-op until badge permission is granted.
    private func updateAppBadge() {
        let count = unreadCount
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                SensorDiagnostics.log("BADGE update failed error=\(error.localizedDescription)")
            }
        }
    }

    private func pruneDismissedEvents() {
        let cutoff = Date().addingTimeInterval(-dismissalRetention)
        dismissedEvents = dismissedEvents.filter { $0.value >= cutoff }
        persistDismissedEvents()
    }

    private func persistDismissedEvents() {
        if let data = try? JSONEncoder().encode(dismissedEvents) {
            defaults.set(data, forKey: dismissedEventsKey)
        }
    }

    private func stableStopDismissalKey(placeName: String, createdAt: Date) -> String {
        let normalizedPlace = placeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let minuteBucket = Int((createdAt.timeIntervalSince1970 / 60).rounded())
        return "stop:\(normalizedPlace):\(minuteBucket)"
    }
}

struct ContextRequestsView: View {
    @ObservedObject var store: ContextRequestStore
    @Environment(\.modelContext) private var modelContext
    @State private var selectedEvent: MemoryEvent?

    var body: some View {
        NavigationStack {
            List {
                if store.requests.isEmpty {
                    ContentUnavailableView("No context requests", systemImage: "bell.slash")
                } else {
                    ForEach(store.requests) { request in
                        Button { open(request) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(request.viewedAt == nil ? KronikuPalette.ember : Color.clear)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 7)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(request.title).font(.headline).foregroundStyle(.primary)
                                    Text(request.message).font(.subheadline).foregroundStyle(.secondary)
                                    Text(request.createdAt.formatted(.dateTime.month().day().hour().minute()))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.delete(request.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Delete notification")
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
            .navigationDestination(item: $selectedEvent) { event in
                ContactMomentDetailView(event: event, startsInEditMode: true)
            }
            .onAppear(perform: openPendingNotification)
            .onChange(of: store.pendingOpenRequestID) { _, _ in
                openPendingNotification()
            }
        }
    }

    private func open(_ request: ContextRequest) {
        store.markViewed(request.id)
        switch request.resolvedAction {
        case .memoryEvent:
            selectedEvent = SwiftDataMemoryRepository(modelContext: modelContext)
                .fetchAll()
                .first { $0.id == request.eventID }
        case .openPlacesSettings:
            NotificationCenter.default.post(name: .openPlacesSettingsRequested, object: nil)
        }
    }

    private func openPendingNotification() {
        guard let requestID = store.consumePendingOpenRequestID(),
              let request = store.requests.first(where: { $0.id == requestID }) else { return }
        open(request)
    }
}