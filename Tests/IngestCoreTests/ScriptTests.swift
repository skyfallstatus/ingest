import AppKit
import Foundation
import Testing

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func executable(_ path: String, _ text: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
}

// This has to fail the way a stale build does, with last time's binaries sitting there and every
// other tool working. Only then is it the pipe that's on trial, so it runs in a copy, with the tools stood in for.
@Test func aFailedCompileStopsTheBuild() throws {
    let tree = temp(), bin = tree + "/bin", old = tree + "/old"
    for folder in ["/scripts", "/Sources/IngestCore", "/Resources", "/bin", "/old"] {
        try FileManager.default.createDirectory(atPath: tree + folder, withIntermediateDirectories: true)
    }
    for rel in ["scripts/build-app.sh", "Sources/IngestCore/AppInfo.swift", "Resources/Info.plist"] {
        try FileManager.default.copyItem(atPath: repo.appendingPathComponent(rel).path, toPath: tree + "/" + rel)
    }
    try "stale".write(toFile: old + "/IngestApp", atomically: true, encoding: .utf8)
    try executable(bin + "/swift", "#!/bin/sh\ncase \"$*\" in *--show-bin-path*) echo \(old);; *) exit 42;; esac\n")
    for tool in ["lipo", "codesign"] { try executable(bin + "/" + tool, "#!/bin/sh\nexit 0\n") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [tree + "/scripts/build-app.sh"]
    p.environment = ["PATH": bin + ":/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus != 0)
    #expect(!FileManager.default.fileExists(atPath: tree + "/dist"), "nothing is packaged")
}

// A tester holding only the disk image has to be able to get past macOS's refusal.
@Test func theDiskImageCarriesTheInstallSteps() throws {
    let steps = try String(contentsOf: repo.appendingPathComponent("Resources/dmg/Read Me First.txt"), encoding: .utf8)
    for needed in ["Open Anyway", "Privacy & Security", "menu bar", "removable volumes", ".ingest", "exFAT"] { #expect(steps.contains(needed), "\(needed)") }
    let script = try String(contentsOf: repo.appendingPathComponent("scripts/build-dmg.sh"), encoding: .utf8)
    #expect(script.contains("Read Me First.txt"))
    let beta = try String(contentsOf: repo.appendingPathComponent("BETA.md"), encoding: .utf8)
    #expect(beta.contains("Open Anyway"), "and so does the note that goes with it")
}

// Everything here ran on one version of macOS, and testers have to be told.
@Test func everyNoteToATesterSaysWhichMacOSIsUntested() throws {
    for rel in ["BETA.md", "README.md", "Resources/dmg/Read Me First.txt"] {
        let text = try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        #expect(text.contains("macOS 14, 15 and 26 are untested"), "\(rel)")
        #expect(text.contains("Intel"), "\(rel)")
    }
}

// A way out nobody can take is worse than none. The app won't copy a file it has just proved.
@Test func noNoteOffersAWayOutThatDoesntExist() throws {
    for rel in ["BETA.md", "docs/SAFETY.md", "README.md", "Resources/dmg/Read Me First.txt"] {
        let text = try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        #expect(!text.contains("copy the card to a new folder"), "\(rel)")
        #expect(!text.contains("to a new folder gives it a clean record"), "\(rel)")
    }
}

// The install steps are what gets a tester past macOS, and their name fell off the window.
@Test func theInstallStepsFitInTheDiskImageWindow() throws {
    let layout = try String(contentsOf: repo.appendingPathComponent("scripts/dmg-layout.py"), encoding: .utf8)
    func number(_ pattern: String) throws -> Int {
        let r = try #require(layout.range(of: pattern, options: .regularExpression))
        return try #require(Int(layout[r].split { !$0.isNumber }.last ?? ""))
    }
    let window = try number(#"WindowBounds": "\{\{240, 180\}, \{600, [0-9]+"#)
    let y = try number(#"Read Me First.txt", b"Iloc", place\(300, [0-9]+"#)
    let image = try #require(NSImage(contentsOf: repo.appendingPathComponent("Resources/dmg/background.tiff")))
    #expect(window - 28 >= y + 64 + 20, "the title bar takes 28, half the icon 64, and its name 20")
    #expect(Int(image.size.height) >= window - 28, "and the background has to reach the bottom")
}

// Report a Bug opens a form, and it's Open GitHub that copies the report.
@Test func theNotesSayHowAReportReallyGoes() throws {
    for rel in ["BETA.md", "Resources/dmg/Read Me First.txt"] {
        let text = try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        #expect(text.contains("Open GitHub copies your report") || text.contains("**Open GitHub** copies your report"), "\(rel)")
    }
}

// A look can't flush, so nothing may call it proof.
@Test func theReadmeSaysALookIsWeakerThanTheApp() throws {
    let text = try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)
    #expect(text.contains("weaker than the app"))
    #expect(!text.contains("proves a card against a drive"))
}

// The stated limits are part of the contract with whoever reads the code.
@Test func theLimitsNameWhatReviewFound() throws {
    let rules = try String(contentsOf: repo.appendingPathComponent("docs/SAFETY.md"), encoding: .utf8)
    for limit in ["exFAT and FAT32", "read-only drive", "between a flush and a read", "weak mark clears", "F_FULLFSYNC", "read cache"] {
        #expect(rules.contains(limit), "\(limit)")
    }
}

// The owner's decision: a cut-off job isn't on hold for good. The notes have to tell that story, and not the old one.
@Test func theNotesTellTheStoryOfACutOffCopy() throws {
    for rel in ["BETA.md", "README.md", "docs/SAFETY.md", "Resources/dmg/Read Me First.txt"] {
        let text = try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        #expect(!text.contains("even after a full read"), "\(rel)")
        #expect(!text.contains("stay on hold for good"), "\(rel)")
    }
    let beta = try String(contentsOf: repo.appendingPathComponent("BETA.md"), encoding: .utf8)
    #expect(beta.contains("Plug it back in"))
    #expect(beta.contains("doesn't match"), "and what happens if something really was lost")
    let rules = try String(contentsOf: repo.appendingPathComponent("docs/SAFETY.md"), encoding: .utf8)
    #expect(rules.contains("refused") && rules.contains("unfinished") && rules.contains("A refusal that couldn't be recorded"))
}

