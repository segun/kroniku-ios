import UIKit
import SwiftData
import UserNotifications

/// Keeps the background-capable providers and the trip correlator alive across a background relaunch
/// (e.g. significant-location-change or HealthKit workout delivery waking the app with no UI on screen).
@MainActor
final class KronikuAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var correlator: TripCorrelator?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Forces CLLocationManager/CMMotionActivityManager/HKHealthStore to exist and hold their
        // delegates/queries before this method returns, per Apple's background-relaunch guidance.
        _ = CoreLocationVisitProvider.shared
        _ = CoreMotionStateProvider.shared
        _ = HealthKitWorkoutObserver.shared

        UNUserNotificationCenter.current().delegate = self
        startCorrelator()

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        resumeMonitoringIfConsented()
    }

    /// Reuses `KronikuModelContainer.shared` — a second, independently created `ModelContainer` for the
    /// same schema/store is unsupported by SwiftData and crashes on the first cross-container insert.
    private func startCorrelator() {
        let repository = SwiftDataMemoryRepository(modelContext: KronikuModelContainer.shared.mainContext)
        let correlator = TripCorrelator(repository: repository)
        self.correlator = correlator
        Task {
            await correlator.start()
            resumeMonitoringIfConsented()
        }
    }

    private func resumeMonitoringIfConsented() {
        guard Tier1ConsentStore().consent.backgroundTripDetectionEnabled else { return }
        CoreLocationVisitProvider.shared.startBackgroundMonitoring()
        CoreMotionStateProvider.shared.startContinuousUpdates()
        HealthKitWorkoutObserver.shared.startBackgroundDelivery()
    }

    /// Shows the notification banner even while Kroniku is in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tapping a "name this place" notification opens the naming sheet via `.namePlaceRequested`.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["kind"] as? String == "namePlace",
           let latitude = userInfo["latitude"] as? Double,
           let longitude = userInfo["longitude"] as? Double {
            Task { @MainActor in
                NotificationCenter.default.post(name: .namePlaceRequested, object: nil, userInfo: ["latitude": latitude, "longitude": longitude])
            }
        }
        if userInfo["kind"] as? String == "tripStop",
           let eventIDRaw = userInfo["eventID"] as? String,
           let eventID = UUID(uuidString: eventIDRaw) {
            Task { @MainActor in
                NotificationCenter.default.post(name: .tripStopContextRequested, object: nil, userInfo: ["eventID": eventID])
            }
        }
        completionHandler()
    }
}
