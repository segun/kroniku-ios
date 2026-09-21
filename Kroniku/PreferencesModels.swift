import Foundation

struct DayPeriodsPreferencePayload: Codable {
    var morningStartMinutes: Int
    var afternoonStartMinutes: Int
    var earlyEveningStartMinutes: Int
    var nightStartMinutes: Int

    init(schedule: DayPeriodSchedule) {
        morningStartMinutes = schedule.morningStartMinutes
        afternoonStartMinutes = schedule.afternoonStartMinutes
        earlyEveningStartMinutes = schedule.earlyEveningStartMinutes
        nightStartMinutes = schedule.nightStartMinutes
    }

    var schedule: DayPeriodSchedule {
        DayPeriodSchedule(
            morningStartMinutes: morningStartMinutes,
            afternoonStartMinutes: afternoonStartMinutes,
            earlyEveningStartMinutes: earlyEveningStartMinutes,
            nightStartMinutes: nightStartMinutes
        )
    }
}

struct PreferencesResponse: Decodable {
    var dayPeriods: DayPeriodsPreferencePayload
    var updatedAt: Date
    var schemaVersion: Int
    var timezoneIdentifier: String?
}

struct PreferencesPatchRequest: Encodable {
    var dayPeriods: DayPeriodsPreferencePayload
}
