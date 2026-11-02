import Foundation
import Testing
@testable import IngestCore

@Suite("Layout dates")
struct LayoutDateTests {
    private func parsed(_ name: String, dayFirst: Bool = true) -> DateName? {
        DateText.parse(name)?.resolved(dayFirst: dayFirst)
    }

    @Test(arguments: [
        ("23.10.26 Regatta day", "dd.MM.yy", 2026, 10, 23),
        ("23-10-26 Regatta day", "dd-MM-yy", 2026, 10, 23),
        ("23_10_26 Regatta day", "dd_MM_yy", 2026, 10, 23),
        ("23.10.2026 Regatta day", "dd.MM.yyyy", 2026, 10, 23),
        ("2026-10-23 Regatta day", "yyyy-MM-dd", 2026, 10, 23),
        ("2026.10.23 Regatta day", "yyyy.MM.dd", 2026, 10, 23),
        ("2026_10_23 Regatta day", "yyyy_MM_dd", 2026, 10, 23),
        ("20261023 Regatta day", "yyyyMMdd", 2026, 10, 23),
        ("261023 Regatta day", "yyMMdd", 2026, 10, 23),
        ("2026-10 Regatta day", "yyyy-MM", 2026, 10, 1),
        ("12 Oct 2026 Regatta day", "dd MMM yyyy", 2026, 10, 12),
        ("12 Oktober 2026 Dreh", "dd MMMM yyyy", 2026, 10, 12),
        ("3 août 2026 Tournage", "d MMM yyyy", 2026, 8, 3),
        ("Oct 12, 2026 Launch", "MMM dd, yyyy", 2026, 10, 12),
        ("29.02.24 Leap", "dd.MM.yy", 2024, 2, 29),
    ] as [(String, String, Int, Int, Int)])
    func readsPrefixDates(name: String, format: String, year: Int, month: Int, day: Int) throws {
        let date = try #require(parsed(name))
        #expect(date.format == format)
        #expect(date.day == CalendarDay(year: year, month: month, day: day))
        #expect(date.position == .prefix)
    }

    @Test func readsSuffixDates() throws {
        let date = try #require(parsed("Emma & Tom 14.06.26"))
        #expect(date.position == .suffix)
        #expect(date.text == "Emma & Tom")
        #expect(date.separator == " ")
        let written = try #require(parsed("Launch - 12 Oct 2026"))
        #expect(written.position == .suffix)
        #expect(written.text == "Launch")
        #expect(written.separator == " - ")
    }

    @Test func splitsSeparatorsAndText() throws {
        let german = try #require(parsed("2026-10-23_Kunde_Dreh"))
        #expect(german.separator == "_")
        #expect(german.text == "Kunde_Dreh")
        let dash = try #require(parsed("2026-10-23 - Launch"))
        #expect(dash.separator == " - ")
    }

    @Test(arguments: [
        "4096", "2026", "1920x1080", "3840x2160", "1920 x 1080", "1080p", "4K", "v1.2.3", "1.2.3", "10.15.7",
        "2.0.1 final", "23.976", "24.00", "2026-2027 SEASON 2", "31.02.26 Nope", "32.10.26 Nope", "2026-13-01 Nope",
        "2026-02-30 Nope", "2026-10-32 Nope", "29.02.26 Not a leap year", "20261332 Nope", "261332 Nope", "123456",
        "01 ORIGINALS", "04_EXPORTS", "1. In-Depth", "C0001", "A001_C002", "16x9", "2026-10-23.4 Nope",
        "2026-10-23x Nope", "FX3", "drive-download-20260705T145813Z-3-001", "OneDrive_1_7-1-2026",
        "Asset-Export-a1b2c3d4-02-07-2025-12-30-31", "1080-60", "3840-2160 master",
    ])
    func rejectsLookalikes(name: String) {
        #expect(DateText.parse(name) == nil, "\(name) is not a date")
    }

    @Test func impossibleOrderIsRejectedOnceTheDriveDecides() {
        #expect(parsed("10.23.26 US", dayFirst: true) == nil)
        #expect(parsed("10.23.26 US", dayFirst: false)?.format == "MM.dd.yy")
        #expect(parsed("23.10.26 EU", dayFirst: false) == nil)
    }

    @Test func monthBuckets() throws {
        #expect(try #require(DateText.parse("2026-10")).isMonthBucket)
        #expect(try #require(DateText.parse("2026-10 October")).isMonthBucket)
        #expect(try #require(DateText.parse("2026-10 Lantern Launch")).isMonthBucket == false)
    }

    @Test func formatsPatterns() {
        let day = CalendarDay(year: 2026, month: 10, day: 3)
        #expect(DateText.format(day, pattern: "dd.MM.yy") == "03.10.26")
        #expect(DateText.format(day, pattern: "yyyy-MM-dd") == "2026-10-03")
        #expect(DateText.format(day, pattern: "yyMMdd") == "261003")
        #expect(DateText.format(day, pattern: "yyyy-MM") == "2026-10")
        #expect(DateText.format(day, pattern: "d MMM yyyy") == "3 Oct 2026")
        #expect(DateText.format(day, pattern: "MMMM dd, yyyy") == "October 03, 2026")
    }
}
