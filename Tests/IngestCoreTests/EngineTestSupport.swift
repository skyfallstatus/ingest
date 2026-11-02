// Real files in a temporary folder, for the engine and safety tests.
import CIngest
import Foundation
@testable import IngestCore

private let faultLock = NSLock()

/// Breaks what only a sick device breaks, for paths holding the given text, for as long as `body` runs. One test at a
/// time: tests run in parallel, and a fault is the whole process's.
func withFaults<T>(noMap: String? = nil, badDir: String? = nil, reserving: (@convention(c) (UnsafePointer<CChar>?, Int32) -> Void)? = nil, _ body: () throws -> T) rethrows -> T {
    faultLock.lock(); defer { faultLock.unlock() }
    let a = noMap.flatMap { strdup($0) }, b = badDir.flatMap { strdup($0) }
    ci_set_faults(a, b, reserving)
    defer { ci_set_faults(nil, nil, nil); free(a); free(b) }
    return try body()
}

/// Everything a run makes goes in one folder, and goes with the run. A suite leaves nothing on the Mac.
private let scratch: String = {
    let p = NSTemporaryDirectory() + "ingest-tests-" + UUID().uuidString
    atexit { try? FileManager.default.removeItem(atPath: scratch) }
    return p
}()

/// A switch a fault hook can flip from the engine's thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Why something that writes until a disk is full wouldn't start.
struct NotItsOwnImage: Error, CustomStringConvertible {
    var description: String
}

/// The image file mounted at `path`, as macOS itself reports it. Nil for anything else, and a plain folder is what a failed attach
/// leaves behind, on the Mac's own disk.
func imageMounted(at path: String) -> String? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    p.arguments = ["info", "-plist"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
          let images = info["images"] as? [[String: Any]] else { return nil }
    for image in images {
        let entities = image["system-entities"] as? [[String: Any]] ?? []
        if entities.contains(where: { $0["mount-point"] as? String == path }) { return image["image-path"] as? String }
    }
    return nil
}

/// Writes to `fd` until it refuses, and never past `limit` bytes, whatever the disk says.
@discardableResult func writeUntilFull(_ fd: Int32, limit: Int) -> Int {
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    var written = 0
    for size in [buf.count, 4096] {
        while written + size <= limit {
            let n = write(fd, &buf, size)
            if n <= 0 { break }
            written += n
        }
    }
    return written
}

func temp() -> String {
    let p = scratch + "/" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

func put(_ path: String, _ d: Data) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! d.write(to: URL(fileURLWithPath: path))
}

func rnd(_ n: Int) -> Data {
    var d = Data(count: n)
    if n > 0 { d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) } }
    return d
}

/// A job for this card, as if nothing else were known about it.
func makeJob(_ read: CardRead, drive: String, dest: String, states: [String: FileState] = [:]) -> IngestJob {
    Pipeline.makeJob(read: read, states: states, cardName: "T", driveRoot: drive, camera: nil,
                     destination: Destination(footageRoot: dest), probe: ProbeResult(hasVideo: true), index: nil)
}

/// Any temp file left on the drive.
func tempFiles(on drive: String) -> [String] {
    (FileManager.default.enumerator(atPath: drive)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".part") }
}

/// Marks every entry in a drive's ledger weak, as if the drive had refused the flush when they were written.
func markLedgerWeak(_ drive: String) throws {
    let folder = drive + "/" + AppInfo.driveFolder + "/ledger/"
    for name in try FileManager.default.contentsOfDirectory(atPath: folder) where name.hasSuffix(".jsonl") {
        let text = try String(contentsOfFile: folder + name, encoding: .utf8)
        try text.replacingOccurrences(of: "\"quick\"", with: "\"weak\":true,\"quick\"")
            .write(toFile: folder + name, atomically: true, encoding: .utf8)
    }
}
