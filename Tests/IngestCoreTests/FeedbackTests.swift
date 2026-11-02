// Bug reports and the update check. What leaves the Mac is decided here, so these tests pin down exactly what that is.
import Foundation
import Testing
@testable import IngestCore

private let macOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)

private func report(_ kind: FeedbackReport.Kind = .bug, _ message: String = "", model: String = "MacBookPro18,3", cameras: [CameraFamily] = []) -> FeedbackReport {
    FeedbackReport(kind: kind, message: message, system: macOS, hardwareModel: model, appleSilicon: true, cameras: cameras)
}

@Suite("Feedback")
struct FeedbackTests {
    @Test func `The details say the version, the Mac and the camera maker, and that is all`() {
        #expect(report(cameras: [.sony]).details == "\(AppInfo.name) \(AppInfo.version) · macOS 26.2 · MacBookPro, Apple silicon · Sony card")
    }

    @Test func `With no card in, no camera is mentioned`() {
        #expect(!report().details.contains("card"))
    }

    @Test func `A camera that couldn't be named adds nothing, and two of a maker count once`() {
        #expect(!report(cameras: [.unknown]).details.contains("card"))
        #expect(report(cameras: [.sony, .canon, .sony]).details.hasSuffix("· Canon, Sony card"))
    }

    @Test func `Only the family of a Mac survives`() {
        #expect(FeedbackReport.family(ofModel: "MacBookPro18,3") == "MacBookPro")
        #expect(FeedbackReport.family(ofModel: "Mac16,7") == "Mac")
        #expect(FeedbackReport.family(ofModel: "Macmini9,1") == "Macmini")
        #expect(FeedbackReport.family(ofModel: "") == "Mac")
        #expect(FeedbackReport.family(ofModel: "7,3") == "Mac")
    }

    @Test func `Nothing typed goes in the address, because an address reaches GitHub the moment it opens`() throws {
        let typed = "Client Example /Volumes/EXAMPLE/Client/clip.mov"
        let r = report(.bug, typed, cameras: [.red])
        let url = try #require(r.issueURL?.absoluteString)
        #expect(url == AppInfo.repoURL + "/issues/new?labels=bug")
        #expect(report(.feature).issueURL?.absoluteString == AppInfo.repoURL + "/issues/new?labels=enhancement")
    }

    @Test func `What gets pasted is the whole report, however long, with the details at the end`() {
        let long = String(repeating: "Ünïcödé text ", count: 3000)
        let r = report(.bug, long, cameras: [.red])
        #expect(r.plainText.hasPrefix(FeedbackReport.Kind.bug.title))
        #expect(r.plainText.contains(long.trimmingCharacters(in: .whitespaces)))
        #expect(r.plainText.hasSuffix(r.details))
    }

    @Test func `An empty report still has the question and the details`() {
        let r = report(.feature)
        #expect(r.plainText.contains(FeedbackReport.Kind.feature.prompt))
        #expect(r.plainText.hasSuffix(r.details))
    }
}
