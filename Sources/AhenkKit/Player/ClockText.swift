import Foundation

/// The desktop clock's text: the time in the chosen 12/24-hour format and
/// the date in the UI language, plus when the next minute starts (the
/// clock redraws once a minute, never every second).
public enum ClockText {
    public struct Time: Hashable, Sendable {
        /// "14:25" or "2:25".
        public var digits: String
        /// "PM", "ÖS"…, only in 12-hour time.
        public var dayPeriod: String?

        public init(digits: String, dayPeriod: String? = nil) {
            self.digits = digits
            self.dayPeriod = dayPeriod
        }
    }

    /// Whether `format` means a 24-hour clock; `.system` asks
    /// `systemUses24Hour` (the Mac's own setting).
    public static func uses24Hour(_ format: ClockFormat, systemUses24Hour: Bool) -> Bool {
        switch format {
        case .system: systemUses24Hour
        case .twelveHour: false
        case .twentyFourHour: true
        }
    }

    /// True when `locale` (with the user's own 12/24-hour choice, for
    /// `Locale.current`) shows hours 0–23.
    public static func localeUses24Hour(_ locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "H"
        return format.contains("H") || format.contains("k")
    }

    public static func time(_ date: Date, twentyFourHour: Bool, locale: Locale, timeZone: TimeZone) -> Time {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if twentyFourHour {
            formatter.dateFormat = "HH:mm"
            return Time(digits: formatter.string(from: date), dayPeriod: nil)
        }
        formatter.dateFormat = "h:mm"
        let digits = formatter.string(from: date)
        formatter.dateFormat = "a"
        let period = formatter.string(from: date).trimmingCharacters(in: .whitespaces)
        return Time(digits: digits, dayPeriod: period.isEmpty ? nil : period)
    }

    /// Weekday, day and month in the locale's own order and words:
    /// "Monday, November 9", "Monday 9 November", "9 Kasım Pazartesi".
    public static func date(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date)
    }

    /// Seconds from `date` to the start of the next minute (never zero).
    public static func secondsToNextMinute(after date: Date, timeZone: TimeZone) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let seconds = Double(calendar.component(.second, from: date))
        let fraction = date.timeIntervalSinceReferenceDate - floor(date.timeIntervalSinceReferenceDate)
        let remaining = 60 - seconds - fraction
        return remaining > 0.001 ? remaining : 60
    }
}
