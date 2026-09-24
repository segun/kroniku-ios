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
        ContextRequestStore.shared.syncAppBadge()
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
        let consent = Tier1ConsentStore().consent
        if consent.backgroundTripDetectionEnabled {
            CoreLocationVisitProvider.shared.startBackgroundMonitoring()
            CoreMotionStateProvider.shared.startContinuousUpdates()
            HealthKitWorkoutObserver.shared.startBackgroundDelivery()
        }
        if consent.sleepTrackingEnabled {
            HealthKitSleepObserver.shared.startBackgroundDelivery()
        }
    }

    /// Context requests are already visible in the in-app inbox, so foreground delivery stays quiet.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["kind"] as? String == "contextRequest" {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["kind"] as? String == "contextRequest",
           let requestIDRaw = userInfo["requestID"] as? String,
           let requestID = UUID(uuidString: requestIDRaw) {
            UserDefaults.standard.set(requestID.uuidString, forKey: "pendingContextRequestID")
            Task { @MainActor in
                NotificationCenter.default.post(name: .contextRequestOpened, object: nil, userInfo: ["requestID": requestID])
            }
        }
        completionHandler()
    }
}
