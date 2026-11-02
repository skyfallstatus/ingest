// Bug reports and the update check. What leaves the Mac is decided here, so these tests pin down exactly what that is.
import Foundation
import Testing
@testable import IngestCore

private let macOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)

private func report(_ kind: FeedbackReport.Kind = .bug, _ message: String = "", model: String = "MacBookPro18,3", cameras: [CameraFamily] = []) -> FeedbackReport {
    FeedbackReport(kind: kind, message: message, system: macOS, hardwareModel: model, appleSilicon: true, cameras: cameras)
}

private func query(_ url: URL?) -> [String: String] {
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
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

    @Test func `Nothing but the typed message and the details goes in the address`() throws {
        let r = report(.bug, "It stopped halfway", cameras: [.red])
        let q = query(r.issueURL)
        #expect(Set(q.keys) == ["title", "body", "labels"])
        #expect(q["title"] == "It stopped halfway")
        #expect(q["body"] == "It stopped halfway\n\n---\n" + r.details)
        #expect(q["labels"] == "bug")
        let url = try #require(r.issueURL?.absoluteString)
        #expect(url.hasPrefix(AppInfo.repoURL + "/issues/new?"))
    }

    @Test func `An empty report still opens, with the question in it`() {
        let q = query(report(.feature).issueURL)
        #expect(q["title"] == "")
        #expect(q["body"]?.hasPrefix(FeedbackReport.Kind.feature.prompt) == true)
        #expect(q["labels"] == "enhancement")
    }

    @Test func `A plus, an ampersand and a newline survive the address`() {
        let q = query(report(.bug, "a+b & c\nd").issueURL)
        #expect(q["body"]?.hasPrefix("a+b & c\nd\n\n---") == true)
        #expect(q["title"] == "a+b & c")
    }

    @Test func `A very long message is cut to fit, says so, and keeps the details`() throws {
        let long = String(repeating: "Ünïcödé text ", count: 3000)
        let r = report(.bug, long)
        let url = try #require(r.issueURL)
        #expect(url.absoluteString.count <= FeedbackReport.longestAddress)
        let body = try #require(query(url)["body"])
        #expect(body.contains("Cut short"))
        #expect(body.hasSuffix(r.details))
        #expect(r.plainText.contains(long.trimmingCharacters(in: .whitespaces)))
    }
}

@Suite("Update check")
struct UpdateCheckTests {
    private func reply(_ tag: String) -> Data { Data(#"{"tag_name":"\#(tag)","html_url":"https://evil.example/"}"#.utf8) }

    @Test func `A newer tag is reported, in plain numbers`() {
        #expect(UpdateCheck.read(status: 200, data: reply("v0.2"), current: "0.1") == .available("0.2"))
        #expect(UpdateCheck.read(status: 200, data: reply("1.10.0"), current: "1.9.3") == .available("1.10.0"))
        #expect(UpdateCheck.read(status: 200, data: reply("v0.2.0-beta.1"), current: "0.1") == .available("0.2.0"))
    }

    @Test func `The same or an older tag is up to date`() {
        #expect(UpdateCheck.read(status: 200, data: reply("v0.1"), current: "0.1") == .upToDate)
        #expect(UpdateCheck.read(status: 200, data: reply("0.1.0"), current: "0.1") == .upToDate)
        #expect(UpdateCheck.read(status: 200, data: reply("v0.0.9"), current: "0.1") == .upToDate)
    }

    @Test func `A private repo's 404 is a failed check, never up to date`() {
        #expect(UpdateCheck.read(status: 404, data: Data(#"{"message":"Not Found"}"#.utf8)) == .failed)
        #expect(UpdateCheck.read(status: 200, data: Data("not json".utf8)) == .failed)
        #expect(UpdateCheck.read(status: 200, data: Data("{}".utf8)) == .failed)
        #expect(UpdateCheck.read(status: 200, data: reply("nightly")) == .failed)
        #expect(UpdateCheck.read(status: 403, data: reply("v9.9")) == .failed)
    }

    @Test func `Both addresses come from the one repo URL, and only ever go to GitHub`() {
        #expect(UpdateCheck.requestURL?.absoluteString == "https://api.github.com/repos/skyfallstatus/card-ingest/releases/latest")
        #expect(UpdateCheck.releasePage?.absoluteString == AppInfo.repoURL + "/releases/latest")
    }
}
