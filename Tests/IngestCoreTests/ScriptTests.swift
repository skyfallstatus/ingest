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

// A healthy card held for empty folders has a way out, and testers have to be told where it is.
@Test func theNotesSayHowToAddMissingFolders() throws {
    let beta = try String(contentsOf: repo.appendingPathComponent("BETA.md"), encoding: .utf8)
    #expect(beta.contains("Add 4 Folders"))
}

@Test func theLicenceIsTheSameEverywhere() throws {
    func text(_ rel: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8) }
    let licence = try text("LICENSE")
    #expect(licence.hasPrefix("MIT License\n\nCopyright (c) 2026 skyfallstatus\n"))
    #expect(licence.contains("Permission is hereby granted, free of charge"))
    #expect(try text("README.md").contains("MIT. See [LICENSE](LICENSE)"))
    #expect(try text("NOTICE").contains("Licensed under the MIT License"))
    for rel in ["README.md", "NOTICE"] { #expect(try !text(rel).contains("All rights reserved"), "\(rel)") }
}

/// The real `scripts/test.sh` around a harmless command, with its own lock, so it can run inside a test run.
private func safety(_ command: String, env: [String: String] = [:], lock: String? = nil) throws -> (code: Int32, said: String, lock: String) {
    let p = Process(), out = Pipe()
    let lockPath = lock ?? (temp() + "/lock")
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [repo.appendingPathComponent("scripts/test.sh").path]
    p.environment = ProcessInfo.processInfo.environment.merging(
        ["INGEST_TEST_COMMAND": command, "INGEST_TEST_LOCK": lockPath, "INGEST_TEST_START_MB": "1", "INGEST_TEST_FLOOR_MB": "1", "INGEST_TEST_DROP_MB": "99999999"].merging(env) { _, new in new }) { _, new in new }
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self), lockPath)
}

private func freeMegabytes() throws -> Int {
    let values = try FileManager.default.attributesOfFileSystem(forPath: "/private/tmp")
    return (values[.systemFreeSize] as? Int ?? 0) >> 20
}

@Test func aRunReturnsWhatItsTestsReturned() throws {
    let r = try safety("exit 7")
    #expect(r.code == 7, "\(r.said)")
    #expect(!FileManager.default.fileExists(atPath: r.lock), "it lets go when it's done")
}

@Test func aRunWontStartWithTooLittleFree() throws {
    let mark = temp() + "/ran"
    let r = try safety("touch \(mark)", env: ["INGEST_TEST_START_MB": "999999999"])
    #expect(r.code == 1, "\(r.said)")
    #expect(r.said.contains("Not starting"))
    #expect(!FileManager.default.fileExists(atPath: mark), "nothing ran")
}

// The real thing, small: 64 MB written against a limit of 8.
@Test func theWatchdogStopsARunThatEatsTheDisk() throws {
    let folder = temp(), pid = folder + "/pid"
    let r = try safety("echo $$ > \(pid); dd if=/dev/urandom of=$TMPDIR/fill bs=1m count=64 2>/dev/null; sleep 60", env: ["INGEST_TEST_DROP_MB": "8"])
    #expect(r.code == 99, "\(r.said)")
    #expect(r.said.contains("stopping the whole run"), "and it says why: \(r.said)")
    #expect(r.said.contains("fell by"))
    let child = Int32(try String(contentsOfFile: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    #expect(kill(child, 0) != 0, "what it started has gone too")
}

@Test func theWatchdogStopsARunBelowTheFloor() throws {
    let r = try safety("sleep 60", env: ["INGEST_TEST_FLOOR_MB": String(try freeMegabytes() + 1000)])
    #expect(r.code == 99, "\(r.said)")
    #expect(r.said.contains("floor"), "\(r.said)")
}

@Test func theTimeLimitStopsARunWithItsOwnWords() throws {
    let folder = temp(), pid = folder + "/pid"
    let r = try safety("echo $$ > \(pid); sleep 77", env: ["INGEST_TEST_SECONDS": "2"])
    #expect(r.code == 98, "\(r.said)")
    #expect(r.said.contains("stopping the whole run") && r.said.contains("limit"), "\(r.said)")
    let child = Int32(try String(contentsOfFile: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    #expect(kill(child, 0) != 0, "what it started has gone too")
}

@Test func theTimeLimitIsTwentyMinutesUnlessSomeoneSays() throws {
    let script = try String(contentsOf: repo.appendingPathComponent("scripts/test.sh"), encoding: .utf8)
    #expect(script.contains("LIMIT=$(( ${INGEST_TEST_MINUTES:-20} * 60 ))"))
}

@Test func aProcessThatCantStartStopsTheRunAtOnce() throws {
    let folder = temp(), pid = folder + "/pid"
    let r = try safety("echo $$ > \(pid); sleep 77", env: ["INGEST_TEST_SPAWN": "/nonexistent/true"])
    #expect(r.code == 97, "\(r.said)")
    #expect(r.said.contains("couldn't be started"), "\(r.said)")
    if let text = try? String(contentsOfFile: pid, encoding: .utf8), let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        #expect(kill(child, 0) != 0, "what it started has gone too")
    }
}

// The real thing: this run alone is held to its own limit on processes, so forks really fail, for it and nothing else.
// A zsh watchdog died at this point and left the tests running, which a test with a pretend path could never show.
@Test func theWatchdogOutlivesARealForkFailure() throws {
    let script = repo.appendingPathComponent("scripts/test.sh").path, lock = temp() + "/lock", pids = temp() + "/pids"
    let mine = getuid()
    let list = Process(), out = Pipe()
    list.executableURL = URL(fileURLWithPath: "/bin/ps")
    list.arguments = ["-axo", "uid="]
    list.standardOutput = out
    try list.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    list.waitUntilExit()
    let count = text.split(separator: "\n").filter { Int($0.trimmingCharacters(in: .whitespaces)) == Int(mine) }.count
    let eat = "perl -e 'for(1..200){ my $p=fork(); last unless defined $p; if(!$p){open(F,\">>\(pids)\");print F \"$$\\n\";close F;sleep 20;exit} } sleep 20'"
    let p = Process(), said = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", "ulimit -u \(count + 40); exec zsh \(script)"]
    p.environment = ProcessInfo.processInfo.environment.merging(
        ["INGEST_TEST_COMMAND": eat, "INGEST_TEST_LOCK": lock, "INGEST_TEST_START_MB": "1", "INGEST_TEST_FLOOR_MB": "1", "INGEST_TEST_DROP_MB": "99999999"]) { _, new in new }
    p.standardOutput = said
    p.standardError = said
    try p.run()
    let words = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    #expect(p.terminationStatus == 97, "\(words)")
    #expect(words.contains("couldn't be started"), "\(words)")
    #expect(!FileManager.default.fileExists(atPath: lock), "it cleared up, on no new processes")
    for line in (try? String(contentsOfFile: pids, encoding: .utf8))?.split(separator: "\n") ?? [] {
        #expect(kill(Int32(line)!, 0) != 0, "nothing it started is left")
    }
}

@Test func oneRunGoesAtATime() throws {
    let lock = temp() + "/lock", mark = temp() + "/ran"
    try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: true)
    try String(getpid()).write(toFile: lock + "/pid", atomically: true, encoding: .utf8)
    let r = try safety("touch \(mark)", lock: lock)
    #expect(r.code == 1, "\(r.said)")
    #expect(r.said.contains("One at a time"))
    #expect(!FileManager.default.fileExists(atPath: mark))
}

@Test func aLockLeftByADeadRunDoesntStopTheNextOne() throws {
    let lock = temp() + "/lock"
    try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: true)
    try "999999".write(toFile: lock + "/pid", atomically: true, encoding: .utf8)
    #expect(try safety("exit 0", lock: lock).code == 0)
}

@Test func aRunsScratchGoesWithIt() throws {
    let note = temp() + "/where"
    #expect(try safety("echo $TMPDIR > \(note); echo x > $TMPDIR/left").code == 0)
    let scratch = try String(contentsOfFile: note, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(scratch.contains("ingest-test-run"))
    #expect(!FileManager.default.fileExists(atPath: scratch))
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

