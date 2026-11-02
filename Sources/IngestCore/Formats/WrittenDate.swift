// Dates as cameras and folders write them.
import Foundation

enum WrittenDate {
    static func isValid(_ d: CalendarDay) -> Bool {
        (2000 ... 2100).contains(d.year) && d.exists
    }

    /// The date digits exactly as written, never converted. Takes "2026-01-20T18:01:11+01:00",
    /// "2026:01:20 18:01:11", "2026/01/20" and "20150317". Free text such as "Monday" gives nil.
    static func day(_ s: String) -> CalendarDay? {
        let u = Array(s.trimmingCharacters(in: .whitespaces).utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= u.count else { return nil }
            var v = 0
            for i in range {
                guard u[i].isASCIIDigit else { return nil }
                v = v * 10 + Int(u[i]) - 48
            }
            return v
        }
        guard let year = number(0 ..< 4) else { return nil }
        var parsed: CalendarDay?
        if u.count >= 10, [45, 58, 47].contains(u[4]), u[4] == u[7], let m = number(5 ..< 7), let d = number(8 ..< 10) {
            parsed = CalendarDay(year: year, month: m, day: d)
        } else if u.count == 8, let m = number(4 ..< 6), let d = number(6 ..< 8) {
            parsed = CalendarDay(year: year, month: m, day: d)
        }
        guard let parsed, isValid(parsed) else { return nil }
        return parsed
    }

    /// yymmdd from a clip name.
    static func yymmdd(_ s: String) -> CalendarDay? {
        guard s.count == 6, let n = Int(s) else { return nil }
        let d = CalendarDay(year: 2000 + n / 10000, month: n / 100 % 100, day: n % 100)
        return isValid(d) ? d : nil
    }

    static func daysApart(_ a: CalendarDay, _ b: CalendarDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let seconds = abs(a.date(in: calendar).timeIntervalSince(b.date(in: calendar)))
        return Int(seconds / 86400)
    }

    static func utcDay(unix: Int64) -> CalendarDay? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(unix)))
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        let day = CalendarDay(year: y, month: m, day: d)
        return isValid(day) ? day : nil
    }

    static func localDay(unix: Int64) -> CalendarDay? {
        let day = CalendarDay(Date(timeIntervalSince1970: TimeInterval(unix)), calendar: Calendar(identifier: .gregorian))
        return isValid(day) ? day : nil
    }
}
