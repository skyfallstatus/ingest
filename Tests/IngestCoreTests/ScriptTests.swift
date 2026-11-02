import Foundation
import Testing

// The review's B11: a failed compile went unheard through a pipe, and last time's binaries were packaged as this build.
@Test func aFailedCompileStopsTheBuild() throws {
    let bin = temp()
    let fake = bin + "/swift"
    try "#!/bin/sh\nexit 42\n".write(toFile: fake, atomically: true, encoding: .utf8)
    chmod(fake, 0o755)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [repo.appendingPathComponent("scripts/build-app.sh").path]
    p.environment = ["PATH": bin + ":/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus != 0)
}
