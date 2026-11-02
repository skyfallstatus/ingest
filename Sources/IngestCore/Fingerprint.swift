import CIngest
import Foundation

public func fingerprint(path: String) -> UInt64? {
    let r = ci_quick_fingerprint(path)
    return r.stage == 0 ? r.hash : nil
}

public func hexHash(_ v: UInt64) -> String {
    let s = String(v, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

/// Names across volumes compare on NFC + case-fold, never on bytes: exFAT lists NFD.
/// Stricter than `LayoutNames.matchKey`, which also folds accents and spaces: the two rules differ on purpose.
public func matchKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
}
