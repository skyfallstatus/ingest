import Foundation
import Testing
@testable import IngestCore

@Suite("Layout performance")
struct LayoutPerformanceTests {
    /// 450,000 entries shaped like a real drive: many clients, deep card trees.
    private func bigDrive(shuffled: Bool) -> [DriveEntry] {
        var entries: [DriveEntry] = []
        entries.reserveCapacity(460_000)
        func folder(_ path: String) { entries.append(DriveEntry(path: path, isDir: true, size: 0, mtime: 1_700_000_000)) }
        var fileNumber = 0
        for clientIndex in 0..<300 {
            let client = "Client \(clientIndex)"
            folder(client)
            for shootIndex in 0..<30 {
                let shoot = "\(client)/2026-\(String(format: "%02d", shootIndex % 12 + 1))-\(String(format: "%02d", shootIndex % 27 + 1)) Shoot \(shootIndex)"
                folder(shoot)
                for inner in ["01 ORIGINALS", "02 ASSETS", "03 PREMIERE", "04 EXPORTS"] { folder("\(shoot)/\(inner)") }
                let card = "\(shoot)/01 ORIGINALS/CARD A\(100 + shootIndex)"
                for part in ["", "/PRIVATE", "/PRIVATE/M4ROOT", "/PRIVATE/M4ROOT/CLIP"] { folder(card + part) }
                for _ in 0..<45 {
                    fileNumber += 1
                    entries.append(DriveEntry(path: "\(card)/PRIVATE/M4ROOT/CLIP/C\(fileNumber).MP4", isDir: false,
                                              size: 2_000_000_000, mtime: 1_700_000_000))
                }
            }
        }
        while entries.count < 450_000 {
            fileNumber += 1
            entries.append(DriveEntry(path: "Client 0/2026-01-01 Shoot 0/02 ASSETS/asset\(fileNumber).png", isDir: false,
                                      size: 1000, mtime: 1_700_000_000))
        }
        if shuffled {
            var generator = SplitMix(state: 42)
            entries.shuffle(using: &generator)
        }
        return entries
    }

    private static let budget: Duration = {
        #if DEBUG
        return .seconds(3)    // unoptimised build; the 1 s budget is enforced on release, see below
        #else
        return .seconds(1)
        #endif
    }()

    @Test("450,000 entries in walk order")
    func walkOrder() throws {
        let entries = bigDrive(shuffled: false)
        #expect(entries.count >= 450_000)
        var setup: DriveSetup?
        let elapsed = ContinuousClock().measure { setup = LayoutLearner.learn(entries: entries) }
        print("learn, walk order, \(entries.count) entries: \(elapsed)")
        #expect(elapsed < Self.budget)
        #expect(setup?.learned?.shootsFound == 9000)
        #expect(setup?.footage == .perCard(prefix: "CARD "))
    }

    @Test("450,000 entries in random order")
    func randomOrder() throws {
        let entries = bigDrive(shuffled: true)
        var setup: DriveSetup?
        let elapsed = ContinuousClock().measure { setup = LayoutLearner.learn(entries: entries) }
        print("learn, shuffled, \(entries.count) entries: \(elapsed)")
        #expect(elapsed < Self.budget)
        #expect(setup?.learned?.shootsFound == 9000)
    }
}
