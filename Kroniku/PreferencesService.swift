import Foundation

/// HTTP methods for the `/v1/me/preferences` resource (day-period schedule, etc.).
final class PreferencesService: @unchecked Sendable {
    static let shared = PreferencesService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func getPreferences() async throws -> PreferencesResponse {
        try await apiClient.get("/v1/me/preferences")
    }

    func updateDayPeriods(_ schedule: DayPeriodSchedule) async throws -> PreferencesResponse {
        let body = PreferencesPatchRequest(dayPeriods: DayPeriodsPreferencePayload(schedule: schedule))
        return try await apiClient.patch("/v1/me/preferences", body: body)
    }
}
