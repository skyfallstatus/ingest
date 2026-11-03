// Headless front end to the same engine the app uses.
import CIngest
import Foundation
import IngestCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { die("usage: ingestctl <hash|look|probe|match|ingest|timings> …") }

let kind: (String) -> FileKind = { CardProber.kind(ofRelativePath: $0) }

func json<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
    return String(data: (try? e.encode(v)) ?? Data(), encoding: .utf8) ?? "{}"
}

func stateName(_ s: FileState?) -> String {
    switch s {
    case .verified: "verified"
    case .likely: "likely"
    case .failed(let w): "failed(\(w))"
    case .missing, nil: "missing"
    }
}

func tally(_ states: [String: FileState]) -> String {
    var c: [String: Int] = [:]
    for s in states.values { c[String(stateName(s).prefix { $0 != "(" }), default: 0] += 1 }
    return c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
}

func verdictLine(_ v: CardVerdict) -> String {
    switch v {
    case .empty: "EMPTY"
    case .safe: "SAFE"
    case .hold(let i): "HOLD: " + i.map(\.message).joined(separator: " | ")
    case .notSafe(let r, let t, let why): "NOT SAFE \(r)/\(t): " + why.prefix(6).joined(separator: " | ")
    }
}

func likelyFiles(_ read: CardRead, _ states: [String: FileState]) -> [(file: CardFile, drivePath: String, quick: String)] {
    read.listing.files.compactMap { f in
        guard case .likely(let p)? = states[f.relPath], let q = read.quick[f.relPath] else { return nil }
        return (f, p, q)
    }
}

switch cmd {
case "hash":
    guard args.count == 2 else { die("ingestctl hash <file>") }
    let r = ci_hash_uncached(args[1], nil, nil, nil)
    guard r.stage == 0 else { die("can't read \(args[1]): \(String(cString: strerror(r.err)))") }
    print(hexHash(r.hash), r.bytes)

case "look":
    guard args.count == 2 else { die("ingestctl look <volume>") }
    print(CardProber.look(atRoot: URL(fileURLWithPath: args[1])))

case "probe":
    guard args.count == 2 else { die("ingestctl probe <card>") }
    let l = listCard(root: args[1], kind: kind)
    print(json(CardProber.probe(root: URL(fileURLWithPath: args[1]), files: l.files, focus: nil)))
    print("files=\(l.files.count) errors=\(l.errors.count)")

case "match":
    // Writes nothing to either side. --confirm reads every likely file in full on both sides, gives the app's
    // verdict, and exits 0 only on Safe.
    guard args.count == 3 || (args.count == 4 && args[3] == "--confirm") else { die("ingestctl match <card> <drive> [--confirm]") }
    let root = args[1], drive = args[2]
    let read = CardReader.read(root: root, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    var states = CardMatcher.match(read: read, ledger: ledger, index: DriveIndex.scan(root: drive), driveRoot: drive)
    print(tally(states), "home:", CardMatcher.existingHome(states: states, files: read.listing.files) ?? "none")
    guard args.count == 4 else { break }
    let checked = IngestEngine.confirm(cardRoot: root, driveRoot: drive, candidates: likelyFiles(read, states), ledger: ledger, jobName: "check",
                                       control: IngestControl(), record: false, progress: { _, _ in })
    for (k, v) in checked.states { states[k] = v }
    let probe = CardProber.probe(root: URL(fileURLWithPath: root), files: read.listing.files, focus: nil)
    let issues = Pipeline.settle(issues: probe.issues, states: states, weak: checked.weak, driveRoot: drive, ledger: ledger)
    let (verdict, final, _) = Pipeline.conclude(read: read, states: states, proved: checked.proofs, issues: issues, driveRoot: drive, kind: kind)
    print(tally(final))
    print(verdictLine(verdict))
    exit(verdict == .safe ? 0 : 1)

case "ingest":
    guard args.count == 4 else { die("ingestctl ingest <card> <drive> <drive-relative-dest>") }
    let root = args[1], drive = args[2], dest = args[3]
    // The app's roots are whole volumes. Folders given here needn't be, and nothing may be written to a card's volume.
    var cardStat = stat(), driveStat = stat()
    guard stat(root, &cardStat) == 0, stat(drive, &driveStat) == 0, cardStat.st_dev != driveStat.st_dev else {
        print("REFUSED: the card and the drive have to be different volumes")
        exit(1)
    }
    let read = CardReader.read(root: root, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let index = DriveIndex.scan(root: drive)
    var states = CardMatcher.match(read: read, ledger: ledger, index: index, driveRoot: drive)
    print("before:", tally(states))
    let control = IngestControl()
    let confirmed = IngestEngine.confirm(cardRoot: root, driveRoot: drive, candidates: likelyFiles(read, states), ledger: ledger, jobName: "check",
                                         control: control, progress: { _, _ in })
    for (k, v) in confirmed.states { states[k] = v }
    let focus = Set(read.listing.files.map(\.relPath).filter { if case .verified? = states[$0] { false } else { true } })
    let probe = CardProber.probe(root: URL(fileURLWithPath: root), files: read.listing.files, focus: focus)
    var job = Pipeline.makeJob(read: read, states: states, proved: confirmed.proofs, cardName: (root as NSString).lastPathComponent, driveRoot: drive,
                               camera: probe.cameras.first?.identity, destination: Destination(footageRoot: dest), probe: probe, index: index)
    // The Mac's own disk keeps room for macOS, as in the app. A volume that won't say counts as the Mac's.
    if (try? URL(fileURLWithPath: drive).resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? true { job.reserve = IngestEngine.macFloor }
    let out: IngestOutcome
    do {
        out = try IngestEngine.run(job: job, ledger: ledger, control: control) { _ in }
    } catch { print("REFUSED:", error.localizedDescription); exit(1) }
    for (k, v) in out.states { states[k] = v }
    if !out.cancelled && out.failures.isEmpty && !job.items.isEmpty { try? Pipeline.writeManifest(job: job, states: states, read: read) }
    let weak = confirmed.weak || out.weakVerification
    let issues = Pipeline.settle(issues: probe.issues, states: states, weak: weak, driveRoot: drive, ledger: ledger)
    let proofs = confirmed.proofs.merging(out.proofs) { _, new in new }
    let (verdict, final, _) = Pipeline.conclude(read: read, states: states, proved: proofs, issues: issues, driveRoot: drive, kind: kind)
    print("after:", tally(final), "cancelled:", out.cancelled, "weak:", weak)
    for (rel, state) in final.sorted(by: { $0.key < $1.key }) where stateName(state) != "verified" {
        print("not proved:", rel, stateName(state), "was", stateName(states[rel]))
    }
    print(verdictLine(verdict))

case "timings":
    // Times each step that happens before any file is read in full. Writes nothing to either side.
    guard args.count == 3 else { die("ingestctl timings <card> <drive>") }
    let root = args[1], drive = args[2]
    func timed<T>(_ name: String, _ work: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let out = work()
        print(String(format: "%-22@ %10.1f ms", name as NSString, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6))
        return out
    }
    let listing = timed("list card") { listCard(root: root, kind: kind) }
    _ = timed("quick fingerprints") { for f in listing.files { _ = fingerprint(path: root + "/" + f.relPath) } }
    let read = timed("read card") { CardReader.read(root: root, kind: kind) }
    let ledger = timed("load ledger") { Ledger(driveRoot: drive) }
    let index = timed("scan drive") { DriveIndex.scan(root: drive) }
    let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ingestctl-timings-\(getpid()).idx")
    defer { try? FileManager.default.removeItem(at: cache) }
    timed("save index") { index.save(to: cache) }
    _ = timed("load index") { DriveIndex.load(from: cache) }
    _ = timed("match") { CardMatcher.match(read: read, ledger: ledger, index: index, driveRoot: drive) }
    _ = timed("probe everything") { CardProber.probe(root: URL(fileURLWithPath: root), files: read.listing.files, focus: nil) }
    _ = timed("probe nothing") { CardProber.probe(root: URL(fileURLWithPath: root), files: read.listing.files, focus: []) }
    print("files=\(read.listing.files.count) drive entries=\(index.entries.count)")

default:
    die("unknown command \(cmd)")
}
