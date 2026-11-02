import Foundation
import Testing

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func executable(_ path: String, _ text: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
}

// The review's B11, and N19: this has to fail the way a stale build does, with last time's binaries sitting there and every
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

// The review's N05: a tester holding only the disk image has to be able to get past macOS's refusal.
@Test func theDiskImageCarriesTheInstallSteps() throws {
    let steps = try String(contentsOf: repo.appendingPathComponent("Resources/dmg/Read Me First.txt"), encoding: .utf8)
    for needed in ["Open Anyway", "Privacy & Security", "menu bar", "removable volumes", ".ingest", "exFAT"] { #expect(steps.contains(needed), "\(needed)") }
    let script = try String(contentsOf: repo.appendingPathComponent("scripts/build-dmg.sh"), encoding: .utf8)
    #expect(script.contains("Read Me First.txt"))
    let beta = try String(contentsOf: repo.appendingPathComponent("BETA.md"), encoding: .utf8)
    #expect(beta.contains("Open Anyway"), "and so does the note that goes with it")
}
