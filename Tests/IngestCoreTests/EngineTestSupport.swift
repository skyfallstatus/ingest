// Real files in a temporary folder, for the engine and safety tests.
import Foundation
@testable import IngestCore

func temp() -> String {
    let p = NSTemporaryDirectory() + "ingest-test-" + UUID().uuidString
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
