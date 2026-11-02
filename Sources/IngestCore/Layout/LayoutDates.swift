// Reading and writing the date in a shoot folder's name. Hand-rolled so a drive-wide scan stays cheap.
import Foundation

/// A folder name that carries a date.
struct DateName {
    /// Two-digit day and month in an unknown order. Settled once, across the whole drive.
    struct Ambiguous: Sendable {
        var first: Int, second: Int, year: Int
        var separator: String
        var yearDigits: Int
    }

    var format: String                      // Unicode pattern. Day-first until `resolved` says otherwise.
    var ambiguous: Ambiguous?
    var day: CalendarDay                    // month-only names use the 1st
    var monthOnly: Bool
    var position: ShootNameStyle.Position
    var separator: String                   // what sits between date and name
    var text: String                        // the name without the date

    /// True for a month folder that holds shoots rather than being one: `2026-10`, `2026-10 October`.
    var isMonthBucket: Bool {
        monthOnly && (text.isEmpty || DateText.monthNumber(text) != nil)
    }

    /// The date under the drive's day/month order, or nil when these numbers cannot be a date in that order.
    func resolved(dayFirst: Bool) -> DateName? {
        guard let ambiguous else { return self }
        let dayValue = dayFirst ? ambiguous.first : ambiguous.second
        let monthValue = dayFirst ? ambiguous.second : ambiguous.first
        guard DateText.isValid(year: ambiguous.year, month: monthValue, day: dayValue) else { return nil }
        var copy = self
        let yearPattern = ambiguous.yearDigits == 4 ? "yyyy" : "yy"
        let sep = ambiguous.separator
        copy.format = dayFirst ? "dd\(sep)MM\(sep)\(yearPattern)" : "MM\(sep)dd\(sep)\(yearPattern)"
        copy.day = CalendarDay(year: ambiguous.year, month: monthValue, day: dayValue)
        copy.ambiguous = nil
        return copy
    }
}

enum DateText {
    // MARK: Parsing

    private struct Match {
        var end: Int
        var format: String
        var ambiguous: DateName.Ambiguous?
        var day: CalendarDay
        var monthOnly: Bool
    }

    /// Reads a date at the start of a name, else at its end. Anything that merely resembles a date is rejected.
    static func parse(_ name: String) -> DateName? {
        let bytes = Array(name.utf8)
        guard bytes.count >= 6 else { return nil }
        if let match = match(bytes, at: 0) {
            return build(bytes, match, start: 0, position: .prefix)
        }
        for start in max(1, bytes.count - 26)..<bytes.count {
            guard canStart(bytes, at: start), let match = match(bytes, at: start), match.end == bytes.count else { continue }
            return build(bytes, match, start: start, position: .suffix)
        }
        return nil
    }

    private static func build(_ bytes: [UInt8], _ match: Match, start: Int, position: ShootNameStyle.Position) -> DateName {
        let rest = position == .prefix
            ? String(decoding: bytes[match.end...], as: UTF8.self)
            : String(decoding: bytes[..<start], as: UTF8.self)
        var scalars = Array(rest.unicodeScalars)
        var separator = ""
        if position == .prefix {
            var count = 0
            while count < scalars.count, isSeparator(scalars[count]) { count += 1 }
            separator = String(String.UnicodeScalarView(scalars[..<count]))
            scalars.removeFirst(count)
        } else {
            var count = 0
            while count < scalars.count, isSeparator(scalars[scalars.count - 1 - count]) { count += 1 }
            separator = String(String.UnicodeScalarView(scalars[(scalars.count - count)...]))
            scalars.removeLast(count)
        }
        let text = String(String.UnicodeScalarView(scalars))
        return DateName(format: match.format, ambiguous: match.ambiguous, day: match.day, monthOnly: match.monthOnly,
                        position: position, separator: text.isEmpty ? "" : separator, text: text)
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "-", "_", ".", ",", ":", "\u{2013}", "\u{2014}", "\u{B7}", "\u{A0}": return true
        default: return false
        }
    }

    private static func isWordByte(_ byte: UInt8) -> Bool { byte.isASCIILetter || byte.isASCIIDigit || byte >= 0x80 }
    private static func isDateSeparator(_ byte: UInt8) -> Bool { byte == 46 || byte == 45 || byte == 95 }

    /// Nothing may run on from a date: `1920x1080` and `2026-10-23.4` both fail here.
    private static func endsCleanly(_ bytes: [UInt8], _ end: Int) -> Bool {
        guard end < bytes.count else { return true }
        if isWordByte(bytes[end]) { return false }
        if bytes[end] == 46, end + 1 < bytes.count, bytes[end + 1].isASCIIDigit { return false }
        return true
    }

    /// A suffix date must stand alone: not the tail of a longer run such as `02-07-2025-12-30-31`.
    private static func canStart(_ bytes: [UInt8], at start: Int) -> Bool {
        let before = bytes[start - 1]
        if isWordByte(before) || isWordByte(bytes[start]) == false { return false }
        if isDateSeparator(before), start >= 2, bytes[start - 2].isASCIIDigit { return false }
        return true
    }

    private static func digitRun(_ bytes: [UInt8], from start: Int) -> Int {
        var cursor = start
        while cursor < bytes.count, bytes[cursor].isASCIIDigit { cursor += 1 }
        return cursor - start
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int {
        var value = 0
        for index in start..<(start + length) { value = value * 10 + Int(bytes[index] - 48) }
        return value
    }

    private static func match(_ bytes: [UInt8], at start: Int) -> Match? {
        let first = bytes[start]
        if first.isASCIIDigit {
            return numeric(bytes, at: start) ?? writtenDayFirst(bytes, at: start)
        }
        return writtenMonthFirst(bytes, at: start)
    }

    private static func numeric(_ bytes: [UInt8], at start: Int) -> Match? {
        let length1 = digitRun(bytes, from: start)
        let end1 = start + length1
        if length1 == 8, endsCleanly(bytes, end1) {
            let year = number(bytes, start, 4), month = number(bytes, start + 4, 2), day = number(bytes, start + 6, 2)
            guard isValid(year: year, month: month, day: day) else { return nil }
            return Match(end: end1, format: "yyyyMMdd", day: CalendarDay(year: year, month: month, day: day), monthOnly: false)
        }
        if length1 == 6, endsCleanly(bytes, end1) {
            guard let year = fullYear(number(bytes, start, 2)) else { return nil }
            let month = number(bytes, start + 2, 2), day = number(bytes, start + 4, 2)
            guard isValid(year: year, month: month, day: day) else { return nil }
            return Match(end: end1, format: "yyMMdd", day: CalendarDay(year: year, month: month, day: day), monthOnly: false)
        }
        guard length1 == 2 || length1 == 4, end1 < bytes.count, isDateSeparator(bytes[end1]) else { return nil }
        let separatorByte = bytes[end1]
        let separator = String(decoding: [separatorByte], as: UTF8.self)
        let start2 = end1 + 1
        guard digitRun(bytes, from: start2) == 2 else { return nil }
        let end2 = start2 + 2
        let value1 = number(bytes, start, length1), value2 = number(bytes, start2, 2)

        if end2 < bytes.count, bytes[end2] == separatorByte {
            let length3 = digitRun(bytes, from: end2 + 1)
            let end3 = end2 + 1 + length3
            if length3 == 2, length1 == 4 {
                let value3 = number(bytes, end2 + 1, 2)
                guard endsCleanly(bytes, end3), isValid(year: value1, month: value2, day: value3) else { return nil }
                return Match(end: end3, format: "yyyy\(separator)MM\(separator)dd",
                             day: CalendarDay(year: value1, month: value2, day: value3), monthOnly: false)
            }
            if length1 == 2, length3 == 2 || length3 == 4 {
                guard endsCleanly(bytes, end3) else { return nil }
                let value3 = number(bytes, end2 + 1, length3)
                guard let year = length3 == 4 ? value3 : fullYear(value3) else { return nil }
                let dayFirst = isValid(year: year, month: value2, day: value1)
                let monthFirst = isValid(year: year, month: value1, day: value2)
                guard dayFirst || monthFirst else { return nil }
                let yearPattern = length3 == 4 ? "yyyy" : "yy"
                let order = dayFirst ? "dd\(separator)MM" : "MM\(separator)dd"
                let day = dayFirst ? CalendarDay(year: year, month: value2, day: value1)
                                   : CalendarDay(year: year, month: value1, day: value2)
                let ambiguous = DateName.Ambiguous(first: value1, second: value2, year: year,
                                                   separator: separator, yearDigits: length3)
                return Match(end: end3, format: "\(order)\(separator)\(yearPattern)", ambiguous: ambiguous,
                             day: day, monthOnly: false)
            }
            // `2026-10-2`, `2026-2027`: not a date we can trust.
            if length1 == 4 { return nil }
        }
        guard length1 == 4, endsCleanly(bytes, end2), isValid(year: value1, month: value2, day: 1) else { return nil }
        return Match(end: end2, format: "yyyy\(separator)MM",
                     day: CalendarDay(year: value1, month: value2, day: 1), monthOnly: true)
    }

    /// `12 Oct 2026`, `12 October 26`, `3-Okt-2026`
    private static func writtenDayFirst(_ bytes: [UInt8], at start: Int) -> Match? {
        let dayDigits = digitRun(bytes, from: start)
        guard dayDigits == 1 || dayDigits == 2 else { return nil }
        let dayEnd = start + dayDigits
        guard dayEnd < bytes.count, bytes[dayEnd] == 32 || isDateSeparator(bytes[dayEnd]) else { return nil }
        let separator = String(decoding: [bytes[dayEnd]], as: UTF8.self)
        guard let word = monthWord(bytes, at: dayEnd + 1) else { return nil }
        guard word.end < bytes.count, bytes[word.end] == bytes[dayEnd] else { return nil }
        let yearStart = word.end + 1
        let yearDigits = digitRun(bytes, from: yearStart)
        guard yearDigits == 2 || yearDigits == 4, endsCleanly(bytes, yearStart + yearDigits) else { return nil }
        let value = number(bytes, yearStart, yearDigits)
        guard let year = yearDigits == 4 ? value : fullYear(value) else { return nil }
        let day = number(bytes, start, dayDigits)
        guard isValid(year: year, month: word.month, day: day) else { return nil }
        let pattern = (dayDigits == 2 ? "dd" : "d") + separator + word.pattern + separator + (yearDigits == 4 ? "yyyy" : "yy")
        return Match(end: yearStart + yearDigits, format: pattern,
                     day: CalendarDay(year: year, month: word.month, day: day), monthOnly: false)
    }

    /// `Oct 12 2026`, `October 12, 2026`, `Oct 2026`
    private static func writtenMonthFirst(_ bytes: [UInt8], at start: Int) -> Match? {
        guard let word = monthWord(bytes, at: start), word.end < bytes.count, bytes[word.end] == 32 else { return nil }
        let next = word.end + 1
        let run = digitRun(bytes, from: next)
        if run == 4 {
            let year = number(bytes, next, 4)
            guard endsCleanly(bytes, next + 4), isValid(year: year, month: word.month, day: 1) else { return nil }
            return Match(end: next + 4, format: "\(word.pattern) yyyy",
                         day: CalendarDay(year: year, month: word.month, day: 1), monthOnly: true)
        }
        guard run == 1 || run == 2 else { return nil }
        var cursor = next + run
        var comma = ""
        if cursor < bytes.count, bytes[cursor] == 44 { comma = ","; cursor += 1 }
        guard cursor < bytes.count, bytes[cursor] == 32 else { return nil }
        cursor += 1
        guard digitRun(bytes, from: cursor) == 4, endsCleanly(bytes, cursor + 4) else { return nil }
        let year = number(bytes, cursor, 4), day = number(bytes, next, run)
        guard isValid(year: year, month: word.month, day: day) else { return nil }
        return Match(end: cursor + 4, format: "\(word.pattern) \(run == 2 ? "dd" : "d")\(comma) yyyy",
                     day: CalendarDay(year: year, month: word.month, day: day), monthOnly: false)
    }

    private static func monthWord(_ bytes: [UInt8], at start: Int) -> (month: Int, end: Int, pattern: String)? {
        var cursor = start
        while cursor < bytes.count, cursor - start <= 12, bytes[cursor].isASCIILetter || bytes[cursor] >= 0x80 { cursor += 1 }
        guard cursor > start, cursor - start <= 12 else { return nil }
        let word = String(decoding: bytes[start..<cursor], as: UTF8.self)
        guard let month = monthNumber(word) else { return nil }
        var end = cursor
        if end < bytes.count, bytes[end] == 46 { end += 1 }  // "Okt."
        return (month, end, word.count > 4 ? "MMMM" : "MMM")
    }

    // MARK: Values

    /// Written months in the languages a drive is likely to use.
    private static let months: [String: Int] = {
        let names: [[String]] = [
            ["jan", "january", "janv", "janvier", "januar", "ene", "enero", "gennaio", "gen", "janeiro", "januari"],
            ["feb", "february", "fev", "fevr", "fevrier", "februar", "febrero", "febbraio", "fevereiro", "februari"],
            ["mar", "march", "mars", "mar", "marz", "maerz", "marzo", "marco", "maart"],
            ["apr", "april", "avr", "avril", "abr", "abril", "aprile"],
            ["may", "mai", "mayo", "maggio", "mag", "maio", "mei"],
            ["jun", "june", "juin", "juni", "junio", "giugno", "giu", "junho"],
            ["jul", "july", "juil", "juillet", "juli", "julio", "luglio", "lug", "julho"],
            ["aug", "august", "aout", "ago", "agosto", "augustus"],
            ["sep", "sept", "september", "septembre", "septiembre", "settembre", "set", "setembro"],
            ["oct", "october", "octobre", "okt", "oktober", "octubre", "ottobre", "ott", "outubro"],
            ["nov", "november", "novembre", "noviembre", "novembro"],
            ["dec", "december", "decembre", "dez", "dezember", "dic", "diciembre", "dicembre", "dezembro"],
        ]
        var table: [String: Int] = [:]
        for (index, words) in names.enumerated() {
            for word in words { table[word] = index + 1 }
        }
        return table
    }()

    static func monthNumber(_ word: String) -> Int? {
        guard !word.isEmpty, word.utf8.count <= 12 else { return nil }
        return months[LayoutNames.matchKey(word)]
    }

    static func fullYear(_ twoDigits: Int) -> Int? {
        switch twoDigits {
        case 0...49: return 2000 + twoDigits
        case 80...99: return 1900 + twoDigits
        default: return nil
        }
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        (1980...2049).contains(year) && CalendarDay(year: year, month: month, day: day).exists
    }

    /// `yyyy-MM` belongs with `yyyy-MM-dd`: same drive habit, one with less precision.
    static func family(of format: String) -> String {
        switch format {
        case "yyyy-MM", "yyyy.MM", "yyyy_MM": return format + String(format[format.index(format.startIndex, offsetBy: 4)]) + "dd"
        default: return format
        }
    }

    // MARK: Formatting

    /// Month words come out in English. UTC throughout: a time zone that skipped a day must not move this one.
    static func format(_ day: CalendarDay, pattern: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: day.date(in: calendar))
    }
}
